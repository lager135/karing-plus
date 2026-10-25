package lfw.fly.vpn_service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import go.Seq
import io.nekohasekai.libbox.BoxService
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * VPN service. Owns the TUN interface (through VpnService.Builder) and the
 * libbox BoxService (sing-box v1.12.x core). The core runs in this process,
 * so the clash API (experimental.clash_api.external_controller) the app
 * connects to on 127.0.0.1 is served from here.
 *
 * State is published through the companion object, which the plugin and the
 * Karing+ broadcast receivers (quick settings tile) read.
 */
class VpnServiceImpl : VpnService() {

    companion object {
        private const val TAG = "VpnServiceImpl"

        const val ACTION_START = "lfw.fly.vpn_service.action.START"
        const val ACTION_STOP = "lfw.fly.vpn_service.action.STOP"
        const val ACTION_RELOAD = "lfw.fly.vpn_service.action.RELOAD"
        const val ACTION_START_RESULT = "lfw.fly.vpn_service.action.START_RESULT"
        const val ACTION_STOPPED = "lfw.fly.vpn_service.action.STOPPED"
        const val ACTION_STATE = "lfw.fly.vpn_service.action.STATE"

        const val EXTRA_STATE = "state"
        const val EXTRA_SUCCESS = "success"
        const val EXTRA_ERROR = "error"

        /**
         * The app's VpnServiceConfig (written by Karing+ into its profile
         * directory, which on Android is filesDir). Read for base_dir/err_path.
         */
        const val service_file_name = "service.json"

        internal const val config_file_name = "vpn_service_config.json"

        private const val CHANNEL_ID = "vpn_service_core"
        private const val NOTIFICATION_ID = 1001

        private val libboxSetupLock = Any()
        @Volatile private var setupBasePath: String? = null
        @Volatile private var stderrRedirected = false

        @Volatile private var currentState: VpnState = VpnState.DISCONNECTED
        @Volatile private var lastError: String? = null
        private val listeners = CopyOnWriteArraySet<VpnStateListener>()

        fun getCurrentState(): VpnState = currentState

        fun getLastError(): String? = lastError

        fun addStateListener(listener: VpnStateListener) {
            listeners.add(listener)
        }

        fun removeStateListener(listener: VpnStateListener) {
            listeners.remove(listener)
        }

        internal fun publishState(state: VpnState, error: String?) {
            if (state == VpnState.CONNECTING) {
                lastError = null
            }
            if (error != null) {
                lastError = error
            }
            currentState = state
            for (listener in listeners) {
                listener.onStateChanged(state, error)
            }
        }

        /** Writes the config atomically so a reader never sees a partial file. */
        internal fun saveConfig(context: Context, json: String) {
            val dir = context.filesDir
            val tmp = File(dir, "$config_file_name.tmp")
            tmp.writeText(json)
            val target = File(dir, config_file_name)
            if (!tmp.renameTo(target)) {
                target.writeText(json)
                tmp.delete()
            }
        }
    }

    private val coreExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "vpn-service-core") }
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var boxService: BoxService? = null
    @Volatile private var platform: VpnPlatformInterface? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Must run promptly after startForegroundService, even for STOP.
        startAsForeground()
        when (intent?.action) {
            ACTION_START -> coreExecutor.execute { startCore(readConfigFile(), startId) }
            ACTION_RELOAD -> coreExecutor.execute { reloadCore(readConfigFile(), startId) }
            ACTION_STOP -> coreExecutor.execute { stopCore(startId) }
            else -> coreExecutor.execute {
                if (boxService == null) {
                    stopSelfClean(startId)
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        Log.w(TAG, "VPN permission revoked by the system or another VPN")
        coreExecutor.execute { stopCore(-1) }
    }

    override fun onDestroy() {
        coreExecutor.execute {
            if (boxService != null || platform != null) {
                teardown()
                setState(VpnState.DISCONNECTED)
            }
        }
        coreExecutor.shutdown()
        super.onDestroy()
    }

    // --- Called by VpnPlatformInterface --------------------------------------

    internal fun onUnderlyingNetworkLost() {
        if (currentState == VpnState.CONNECTED) {
            setState(VpnState.REASSERTING)
        }
    }

    internal fun onUnderlyingNetworkAvailable() {
        if (currentState == VpnState.REASSERTING) {
            setState(VpnState.CONNECTED)
        }
    }

    // --- Core control (runs on coreExecutor) ---------------------------------

    private fun startCore(config: String?, startId: Int) {
        if (config.isNullOrEmpty()) {
            failStart("no configuration was provided to the VPN service", startId)
            return
        }
        if (boxService != null || platform != null) {
            teardown()
        }
        setState(VpnState.CONNECTING)
        val pi = VpnPlatformInterface(this)
        var service: BoxService? = null
        try {
            ensureLibboxSetup()
            // Throws on a config error, e.g. `decode config at ...: json: unknown field "x"`.
            service = Libbox.newService(config, pi)
            platform = pi
            boxService = service
            service.start()
            setState(VpnState.CONNECTED)
            broadcast(ACTION_START_RESULT) { putExtra(EXTRA_SUCCESS, true) }
        } catch (t: Throwable) {
            Log.e(TAG, "start failed", t)
            if (boxService == null) {
                // newService failed: nothing was handed to the core.
                pi.close()
            }
            failStart(describe(t), startId)
        }
    }

    /** libbox 1.12 has no in-place reload without the command server: restart the core. */
    private fun reloadCore(config: String?, startId: Int) {
        if (config.isNullOrEmpty()) {
            failStart("no configuration was provided to the VPN service", startId)
            return
        }
        if (boxService != null || platform != null) {
            setState(VpnState.DISCONNECTING)
            teardown()
        }
        startCore(config, startId)
    }

    private fun stopCore(startId: Int) {
        setState(VpnState.DISCONNECTING)
        teardown()
        setState(VpnState.DISCONNECTED)
        broadcast(ACTION_STOPPED)
        stopSelfClean(startId)
    }

    private fun failStart(message: String, startId: Int) {
        setState(VpnState.INVALID, message)
        broadcast(ACTION_START_RESULT) {
            putExtra(EXTRA_SUCCESS, false)
            putExtra(EXTRA_ERROR, message)
        }
        teardown()
        setState(VpnState.DISCONNECTED)
        broadcast(ACTION_STOPPED)
        stopSelfClean(startId)
    }

    private fun teardown() {
        val service = boxService
        boxService = null
        if (service != null) {
            try {
                service.close()
            } catch (t: Throwable) {
                Log.w(TAG, "BoxService.close failed", t)
            }
        }
        // After the core is closed: releases the network callback and our TUN descriptor.
        platform?.close()
        platform = null
    }

    /**
     * Stops the service unless a newer start command arrived meanwhile
     * (Dart retries start right after a config error). startId -1 stops always.
     */
    private fun stopSelfClean(startId: Int) {
        mainHandler.post {
            if (startId == -1) {
                stopForegroundCompat()
                stopSelf()
            } else if (stopSelfResult(startId)) {
                stopForegroundCompat()
            }
        }
    }

    // --- libbox setup --------------------------------------------------------

    /**
     * The core resolves relative paths in the config (log output
     * "service_core.log", cache_file "cache.db") against the working path,
     * so it is the app's profile directory (VpnServiceConfig.base_dir; on
     * Android that is filesDir).
     */
    private fun ensureLibboxSetup() {
        synchronized(libboxSetupLock) {
            val serviceConfig = readServiceConfig()
            val base = serviceConfig?.optString("base_dir")?.takeIf { it.isNotEmpty() }
                ?: filesDir.absolutePath
            if (setupBasePath == base) {
                return
            }
            Seq.setContext(applicationContext)
            File(base).mkdirs()
            val temp = File(cacheDir, "libbox").apply { mkdirs() }
            val options = SetupOptions()
            options.basePath = base
            options.workingPath = base
            options.tempPath = temp.absolutePath
            options.fixAndroidStack = true
            Libbox.setup(options)
            setupBasePath = base
            if (!stderrRedirected) {
                val errPath = serviceConfig?.optString("err_path")?.takeIf { it.isNotEmpty() }
                    ?: File(base, "service_error.log").absolutePath
                try {
                    Libbox.redirectStderr(errPath)
                    stderrRedirected = true
                } catch (t: Throwable) {
                    Log.w(TAG, "redirectStderr failed", t)
                }
            }
        }
    }

    private fun readServiceConfig(): JSONObject? = try {
        val file = File(filesDir, service_file_name)
        if (file.isFile) JSONObject(file.readText()) else null
    } catch (e: Exception) {
        Log.w(TAG, "reading $service_file_name failed", e)
        null
    }

    // --- Foreground service and broadcasts -----------------------------------

    private fun startAsForeground() {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "VPN core",
                        NotificationManager.IMPORTANCE_LOW,
                    ),
                )
            }
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch != null) {
            val flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE
            builder.setContentIntent(android.app.PendingIntent.getActivity(this, 0, launch, flags))
        }
        val notification = builder
            .setContentTitle(applicationInfo.loadLabel(packageManager))
            .setContentText("VPN is running")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun setState(state: VpnState, error: String? = null) {
        publishState(state, error)
        broadcast(ACTION_STATE) { putExtra(EXTRA_STATE, state.name) }
    }

    /** Broadcasts stay inside this app (the Karing+ tile and receivers). */
    private fun broadcast(action: String, configure: Intent.() -> Unit = {}) {
        val intent = Intent(action).setPackage(packageName)
        intent.configure()
        sendBroadcast(intent)
    }

    private fun readConfigFile(): String? {
        val file = File(filesDir, config_file_name)
        return if (file.isFile) file.readText() else null
    }

    private fun describe(t: Throwable): String = t.message ?: t.javaClass.simpleName
}
