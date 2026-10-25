package lfw.fly.vpn_service

import android.app.ActivityManager
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Flutter entry point. Method calls go to the MethodChannel
 * "lfw.fly.vpn_service/methods". State changes go to the EventChannel
 * "lfw.fly.vpn_service/state".
 */
class VpnServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    EventChannel.StreamHandler, VpnStateListener {

    private companion object {
        const val METHOD_CHANNEL = "lfw.fly.vpn_service/methods"
        const val EVENT_CHANNEL = "lfw.fly.vpn_service/state"
        const val REQUEST_PREPARE = 0x5650
        const val DEFAULT_TIMEOUT_MS = 30_000L
    }

    private enum class OpKind { START, STOP }

    private class PendingOp(
        val kind: OpKind,
        val result: MethodChannel.Result,
        val timeoutRunnable: Runnable,
    )

    private lateinit var appContext: Context
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPrepare: MethodChannel.Result? = null
    private var pendingOp: PendingOp? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private val activityResultListener = PluginRegistry.ActivityResultListener { requestCode, resultCode, _ ->
        if (requestCode != REQUEST_PREPARE) {
            return@ActivityResultListener false
        }
        val result = pendingPrepare
        pendingPrepare = null
        result?.success(resultCode == Activity.RESULT_OK)
        true
    }

    // --- FlutterPlugin ------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        attachChannels(binding.binaryMessenger)
        VpnServiceImpl.addStateListener(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        VpnServiceImpl.removeStateListener(this)
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        eventSink = null
        failPending("the Flutter engine was detached")
    }

    private fun attachChannels(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(messenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    // --- ActivityAware (needed for the VPN permission dialog) ---------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(activityResultListener)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(activityResultListener)
        activityBinding = null
    }

    // --- EventChannel -------------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        events.success(VpnServiceImpl.getCurrentState().name.lowercase())
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    /** Called on the thread that changed the state. Hops to the main thread. */
    override fun onStateChanged(state: VpnState, error: String?) {
        mainHandler.post {
            eventSink?.success(state.name.lowercase())
            val op = pendingOp ?: return@post
            when (op.kind) {
                OpKind.START -> when (state) {
                    VpnState.CONNECTED -> finishPending(null)
                    VpnState.INVALID -> finishPending(error ?: "the VPN core failed to start")
                    else -> Unit
                }
                OpKind.STOP -> if (state == VpnState.DISCONNECTED) finishPending(null)
            }
        }
    }

    // --- MethodChannel ------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> prepare(result)
            "start" -> start(call, result)
            "reload" -> reload(call, result)
            "stop" -> stop(call, result)
            "getState" -> result.success(VpnServiceImpl.getCurrentState().name.lowercase())
            "getSystemVersion" ->
                result.success("Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
            "setExcludeFromRecents" -> setExcludeFromRecents(call, result)
            "setAlwaysOn" -> result.success(null)
            // Dart strips the brackets and splits on ",".
            "getABIs" -> result.success(Build.SUPPORTED_ABIS.joinToString(",", "[", "]"))            else -> result.notImplemented()
        }
    }

    private fun prepare(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
            ?: return result.error("NO_ACTIVITY", "VPN permission needs an attached Activity", null)
        val intent = VpnService.prepare(activity)
        if (intent == null) {
            result.success(true)
            return
        }
        if (pendingPrepare != null) {
            result.error("BUSY", "another VPN permission request is pending", null)
            return
        }
        pendingPrepare = result
        @Suppress("DEPRECATION")
        activity.startActivityForResult(intent, REQUEST_PREPARE)
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val state = VpnServiceImpl.getCurrentState()
        if (state != VpnState.DISCONNECTED && state != VpnState.INVALID) {
            result.success("the VPN core is already running; use reload")
            return
        }
        beginOperation(call, result, OpKind.START, VpnServiceImpl.ACTION_START)
    }

    private fun reload(call: MethodCall, result: MethodChannel.Result) {
        val state = VpnServiceImpl.getCurrentState()
        if (state != VpnState.CONNECTED && state != VpnState.REASSERTING) {
            result.success("the VPN core is not running; use start")
            return
        }
        beginOperation(call, result, OpKind.START, VpnServiceImpl.ACTION_RELOAD)
    }

    private fun stop(call: MethodCall, result: MethodChannel.Result) {
        if (VpnServiceImpl.getCurrentState() == VpnState.DISCONNECTED) {
            result.success(null)
            return
        }
        if (pendingOp != null) {
            result.success("another VPN operation is in progress")
            return
        }
        val timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: DEFAULT_TIMEOUT_MS
        val op = PendingOp(OpKind.STOP, result, Runnable { finishPending("timed out waiting for the VPN core to stop") })
        pendingOp = op
        mainHandler.postDelayed(op.timeoutRunnable, timeoutMs)
        try {
            sendToService(VpnServiceImpl.ACTION_STOP)
        } catch (e: Exception) {
            finishPending(e.message ?: "failed to send stop to the VPN service")
        }
    }

    /** Sends start or reload. The op finishes when the state changes to CONNECTED or INVALID. */
    private fun beginOperation(
        call: MethodCall,
        result: MethodChannel.Result,
        kind: OpKind,
        action: String,
    ) {
        val config = call.argument<String>("config")
        if (config.isNullOrEmpty()) {
            result.success("empty configuration")
            return
        }
        if (pendingOp != null) {
            result.success("another VPN operation is in progress")
            return
        }
        val timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: DEFAULT_TIMEOUT_MS
        try {
            VpnServiceImpl.saveConfig(appContext, config)
        } catch (e: Exception) {
            result.success("failed to save configuration: ${e.message}")
            return
        }
        val op = PendingOp(kind, result, Runnable { finishPending("timed out waiting for the VPN core") })
        pendingOp = op
        mainHandler.postDelayed(op.timeoutRunnable, timeoutMs)
        try {
            sendToService(action)
        } catch (e: Exception) {
            finishPending(e.message ?: "failed to start the VPN service")
        }
    }

    private fun sendToService(action: String) {
        val intent = Intent(appContext, VpnServiceImpl::class.java).setAction(action)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            appContext.startForegroundService(intent)
        } else {
            appContext.startService(intent)
        }
    }

    /** Completes the pending start/stop. Error is null on success. Runs on the main thread. */
    private fun finishPending(error: String?) {
        val op = pendingOp ?: return
        pendingOp = null
        mainHandler.removeCallbacks(op.timeoutRunnable)
        op.result.success(error)
    }

    private fun failPending(message: String) {
        mainHandler.post { finishPending(message) }
    }

    private fun setExcludeFromRecents(call: MethodCall, result: MethodChannel.Result) {
        val value = call.argument<Boolean>("value") ?: false
        val activity = activityBinding?.activity
        if (activity == null) {
            result.success("no Activity is attached")
            return
        }
        val manager = activity.getSystemService(ActivityManager::class.java)
        manager.appTasks.forEach { it.setExcludeFromRecents(value) }
        result.success(null)
    }
}
