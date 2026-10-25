package lfw.fly.vpn_service

import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.ProxyInfo
import android.net.VpnService
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Log
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification as LibboxNotification
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.RoutePrefixIterator
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface as JavaNetworkInterface
import java.security.KeyStore
import java.util.Collections

/**
 * Android side of libbox's PlatformInterface for libbox built from sing-box
 * v1.12.x (18 methods): TUN creation, socket protection, the default-network
 * monitor, interface listing, the platform "local" DNS transport, connection
 * owner lookup, Wi-Fi state and system certificates.
 *
 * In libbox 1.12 the core dup()s the TUN descriptor returned by [openTun], so
 * this class keeps the ParcelFileDescriptor and closes it in [close].
 */
class VpnPlatformInterface(private val service: VpnServiceImpl) : PlatformInterface {

    private val connectivity: ConnectivityManager =
        service.getSystemService(ConnectivityManager::class.java)

    private val lock = Any()
    private var tunFd: ParcelFileDescriptor? = null
    private var monitorThread: HandlerThread? = null
    private var defaultCallback: ConnectivityManager.NetworkCallback? = null
    private var defaultListener: InterfaceUpdateListener? = null

    @Volatile
    private var defaultNetwork: Network? = null

    private val localResolver = LocalResolver(this)

    /** The current underlying (non-VPN) default network, or null. */
    internal fun currentNetwork(): Network? = defaultNetwork

    // --- TUN -----------------------------------------------------------------

    override fun openTun(options: TunOptions): Int {
        if (VpnService.prepare(service) != null) {
            throw IllegalStateException("android: missing vpn permission")
        }
        // VpnService.Builder is an inner class, so it is created from the service instance.
        val builder = service.Builder()
        builder.setSession("sing-box")
        builder.setMtu(options.getMTU())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        val inet4Address = options.getInet4Address().drain()
        val inet6Address = options.getInet6Address().drain()
        for (prefix in inet4Address) {
            builder.addAddress(prefix.address(), prefix.prefix())
        }
        for (prefix in inet6Address) {
            builder.addAddress(prefix.address(), prefix.prefix())
        }

        if (options.getAutoRoute()) {
            builder.addDnsServer(options.getDNSServerAddress().getValue())

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val routes4 = options.getInet4RouteAddress().drain()
                if (routes4.isNotEmpty()) {
                    routes4.forEach { builder.addRoute(it.toIpPrefix()) }
                } else if (inet4Address.isNotEmpty()) {
                    builder.addRoute(IpPrefix(InetAddress.getByName("0.0.0.0"), 0))
                }
                val routes6 = options.getInet6RouteAddress().drain()
                if (routes6.isNotEmpty()) {
                    routes6.forEach { builder.addRoute(it.toIpPrefix()) }
                } else if (inet6Address.isNotEmpty()) {
                    builder.addRoute(IpPrefix(InetAddress.getByName("::"), 0))
                }
                options.getInet4RouteExcludeAddress().drain()
                    .forEach { builder.excludeRoute(it.toIpPrefix()) }
                options.getInet6RouteExcludeAddress().drain()
                    .forEach { builder.excludeRoute(it.toIpPrefix()) }
            } else {
                // Route ranges already have the excluded addresses cut out.
                options.getInet4RouteRange().drain()
                    .forEach { builder.addRoute(it.address(), it.prefix()) }
                options.getInet6RouteRange().drain()
                    .forEach { builder.addRoute(it.address(), it.prefix()) }
            }

            // addAllowedApplication and addDisallowedApplication cannot be mixed.
            val include = options.getIncludePackage().drainStrings()
            val exclude = options.getExcludePackage().drainStrings()
            if (include.isNotEmpty()) {
                for (pkg in include) {
                    addApplication(pkg) { builder.addAllowedApplication(it) }
                }
            } else {
                for (pkg in exclude) {
                    addApplication(pkg) { builder.addDisallowedApplication(it) }
                }
            }
        }

        if (options.isHTTPProxyEnabled() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val bypass = options.getHTTPProxyBypassDomain().drainStrings()
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.getHTTPProxyServer(),
                    options.getHTTPProxyServerPort(),
                    bypass,
                ),
            )
        }

        val pfd = builder.establish()
            ?: throw IllegalStateException("android: the application is not prepared or is revoked")
        val previous: ParcelFileDescriptor?
        synchronized(lock) {
            previous = tunFd
            tunFd = pfd
        }
        closeQuietly(previous)
        // libbox dup()s this descriptor; ours is closed in close().
        return pfd.fd
    }

    private inline fun addApplication(pkg: String, action: (String) -> Unit) {
        try {
            action(pkg)
        } catch (e: PackageManager.NameNotFoundException) {
            Log.w(TAG, "package not found for VPN routing: $pkg")
        }
    }

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        if (!service.protect(fd)) {
            throw IllegalStateException("VpnService.protect($fd) failed")
        }
    }

    // --- Default network monitor --------------------------------------------

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val thread = HandlerThread("vpn-service-network").also { it.start() }
        val handler = Handler(thread.looper)
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                setDefaultNetwork(network)
            }

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                if (network == defaultNetwork) setDefaultNetwork(network)
            }

            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                if (network == defaultNetwork) setDefaultNetwork(network)
            }

            override fun onLost(network: Network) {
                if (network == defaultNetwork) setDefaultNetwork(null)
            }
        }
        synchronized(lock) {
            defaultListener = listener
            defaultCallback = callback
            monitorThread = thread
        }
        // Push the current physical network first, so the core has an interface
        // before the first callback arrives.
        val active = connectivity.activeNetwork
        val activeCaps = active?.let { connectivity.getNetworkCapabilities(it) }
        if (active != null && activeCaps != null &&
            !activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        ) {
            setDefaultNetwork(active)
        }
        // A NetworkRequest carries NOT_VPN by default, so our own TUN is never chosen.
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            connectivity.registerBestMatchingNetworkCallback(request, callback, handler)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            connectivity.requestNetwork(request, callback, handler)
        } else {
            connectivity.requestNetwork(request, callback)
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        stopMonitor()
    }

    private fun stopMonitor() {
        val callback: ConnectivityManager.NetworkCallback?
        val thread: HandlerThread?
        synchronized(lock) {
            callback = defaultCallback
            thread = monitorThread
            defaultCallback = null
            defaultListener = null
            monitorThread = null
        }
        defaultNetwork = null
        if (callback != null) {
            try {
                connectivity.unregisterNetworkCallback(callback)
            } catch (e: IllegalArgumentException) {
                Log.w(TAG, "network callback was already unregistered")
            }
        }
        thread?.quitSafely()
    }

    private fun setDefaultNetwork(network: Network?) {
        defaultNetwork = network
        val listener = synchronized(lock) { defaultListener } ?: return
        if (network == null) {
            try {
                service.setUnderlyingNetworks(null)
            } catch (_: Exception) {
            }
            listener.updateDefaultInterface("", -1, false, false)
            service.onUnderlyingNetworkLost()
            return
        }
        val name = connectivity.getLinkProperties(network)?.interfaceName ?: return
        var index = -1
        for (attempt in 0 until 10) {
            index = try {
                JavaNetworkInterface.getByName(name)?.index ?: -1
            } catch (e: Exception) {
                -1
            }
            if (index != -1) break
            Thread.sleep(100)
        }
        if (index == -1) {
            Log.w(TAG, "no interface index for $name")
            return
        }
        val caps = connectivity.getNetworkCapabilities(network)
        val expensive = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
        try {
            service.setUnderlyingNetworks(arrayOf(network))
        } catch (_: Exception) {
        }
        listener.updateDefaultInterface(name, index, expensive, false)
        service.onUnderlyingNetworkAvailable()
    }

    // --- Interfaces ----------------------------------------------------------

    @Suppress("DEPRECATION")
    override fun getInterfaces(): NetworkInterfaceIterator {
        val typeByName = HashMap<String, Int>()
        val meteredByName = HashMap<String, Boolean>()
        val dnsByName = HashMap<String, List<String>>()
        for (network in connectivity.allNetworks) {
            val link = connectivity.getLinkProperties(network) ?: continue
            val name = link.interfaceName ?: continue
            val caps = connectivity.getNetworkCapabilities(network)
            if (caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true) continue
            typeByName[name] = interfaceType(caps)
            meteredByName[name] =
                caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
            dnsByName[name] = link.dnsServers.mapNotNull { it.hostAddress?.substringBefore('%') }
        }

        val items = ArrayList<LibboxNetworkInterface>()
        val javaInterfaces = JavaNetworkInterface.getNetworkInterfaces()
            ?.let { Collections.list(it) } ?: emptyList()
        for (iface in javaInterfaces) {
            val item = LibboxNetworkInterface()
            item.setName(iface.name)
            item.setIndex(iface.index)
            try {
                item.setMTU(iface.mtu)
            } catch (_: Exception) {
            }
            item.setFlags(goFlags(iface))
            item.setType(typeByName[iface.name] ?: Libbox.InterfaceTypeOther)
            item.setAddresses(
                ListStringIterator(
                    iface.interfaceAddresses.mapNotNull { address ->
                        val inet = address.address ?: return@mapNotNull null
                        val host = inet.hostAddress?.substringBefore('%') ?: return@mapNotNull null
                        val bits = address.networkPrefixLength.toInt()
                        val max = if (inet is Inet6Address) 128 else 32
                        if (bits < 0 || bits > max) return@mapNotNull null
                        "$host/$bits"
                    },
                ),
            )
            item.setDNSServer(ListStringIterator(dnsByName[iface.name] ?: emptyList()))
            item.setMetered(meteredByName[iface.name] ?: false)
            items.add(item)
        }
        return ListNetworkInterfaceIterator(items)
    }

    private fun interfaceType(caps: NetworkCapabilities?): Int = when {
        caps == null -> Libbox.InterfaceTypeOther
        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
        else -> Libbox.InterfaceTypeOther
    }

    /** Go net.Flags bits: FlagUp=1, FlagLoopback=4, FlagPointToPoint=8, FlagMulticast=16. */
    private fun goFlags(iface: JavaNetworkInterface): Int {
        var flags = 0
        try {
            if (iface.isUp) flags = flags or 1
            if (iface.isLoopback) flags = flags or 4
            if (iface.isPointToPoint) flags = flags or 8
            if (iface.supportsMulticast()) flags = flags or 16
        } catch (_: Exception) {
        }
        return flags
    }

    // --- Process lookup ------------------------------------------------------

    /** /proc/net is not readable on Android 10+. */
    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw UnsupportedOperationException("connection owner lookup needs Android 10")
        }
        val uid = connectivity.getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort),
        )
        if (uid == android.os.Process.INVALID_UID) {
            throw IllegalStateException("android: connection owner not found")
        }
        return uid
    }

    override fun packageNameByUid(uid: Int): String {
        val packages = service.packageManager.getPackagesForUid(uid)
        if (packages.isNullOrEmpty()) {
            throw IllegalStateException("android: package for uid $uid not found")
        }
        return packages[0]
    }

    override fun uidByPackageName(packageName: String): Int =
        service.packageManager.getApplicationInfo(packageName, 0).uid

    // --- DNS, Wi-Fi, certificates -------------------------------------------

    override fun localDNSTransport(): LocalDNSTransport = localResolver

    override fun clearDNSCache() {}

    @Suppress("DEPRECATION")
    override fun readWIFIState(): WIFIState? {
        return try {
            val wifi = service.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val info = wifi.connectionInfo ?: return null
            var ssid = info.ssid ?: return null
            if (ssid == "<unknown ssid>") return null
            if (ssid.length >= 2 && ssid.startsWith("\"") && ssid.endsWith("\"")) {
                ssid = ssid.substring(1, ssid.length - 1)
            }
            Libbox.newWIFIState(ssid, info.bssid ?: "")
        } catch (e: Exception) {
            null
        }
    }

    /** System and user CA certificates as PEM, for the core's "system" certificate store. */
    override fun systemCertificates(): StringIterator {
        val certificates = ArrayList<String>()
        try {
            val keyStore = KeyStore.getInstance("AndroidCAStore")
            keyStore.load(null, null)
            for (alias in Collections.list(keyStore.aliases())) {
                val cert = keyStore.getCertificate(alias) ?: continue
                certificates.add(
                    "-----BEGIN CERTIFICATE-----\n" +
                        Base64.encodeToString(cert.encoded, Base64.DEFAULT) +
                        "-----END CERTIFICATE-----",
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "reading AndroidCAStore failed", e)
        }
        return ListStringIterator(certificates)
    }

    // --- Misc ----------------------------------------------------------------

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun writeLog(message: String) {
        Log.d(CORE_TAG, message)
    }

    override fun sendNotification(notification: LibboxNotification) {
        Log.i(TAG, "core notification: ${notification.getTitle()} - ${notification.getBody()}")
    }

    /** Releases the default-network callback and the TUN descriptor. Call after the core is closed. */
    fun close() {
        stopMonitor()
        val pfd: ParcelFileDescriptor?
        synchronized(lock) {
            pfd = tunFd
            tunFd = null
        }
        closeQuietly(pfd)
    }

    private fun closeQuietly(pfd: ParcelFileDescriptor?) {
        try {
            pfd?.close()
        } catch (e: Exception) {
            Log.w(TAG, "closing the TUN descriptor failed", e)
        }
    }

    companion object {
        private const val TAG = "VpnPlatformInterface"
        private const val CORE_TAG = "sing-box"
    }
}

private fun RoutePrefix.toIpPrefix(): IpPrefix =
    IpPrefix(InetAddress.getByName(address()), prefix())

private fun RoutePrefixIterator.drain(): List<RoutePrefix> {
    val out = ArrayList<RoutePrefix>()
    while (hasNext()) {
        out.add(next())
    }
    return out
}

private fun StringIterator.drainStrings(): List<String> {
    val out = ArrayList<String>()
    while (hasNext()) {
        out.add(next())
    }
    return out
}

private class ListStringIterator(private val items: List<String>) : StringIterator {
    private var index = 0

    override fun hasNext(): Boolean = index < items.size

    override fun next(): String = items[index++]

    override fun len(): Int = items.size
}

private class ListNetworkInterfaceIterator(
    private val items: List<LibboxNetworkInterface>,
) : NetworkInterfaceIterator {
    private var index = 0

    override fun hasNext(): Boolean = index < items.size

    override fun next(): LibboxNetworkInterface = items[index++]
}
