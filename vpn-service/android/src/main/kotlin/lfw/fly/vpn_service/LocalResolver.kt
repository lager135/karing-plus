package lfw.fly.vpn_service

import android.net.DnsResolver
import android.os.Build
import android.os.CancellationSignal
import android.system.ErrnoException
import android.annotation.TargetApi
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.Func
import io.nekohasekai.libbox.LocalDNSTransport
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

/**
 * The core's "local" DNS server on Android. Without it libbox falls back to
 * /etc/resolv.conf, which does not exist on Android. Queries go to the
 * underlying (non-VPN) default network, so they never loop through the TUN.
 *
 * Android 10+: raw DNS messages through DnsResolver. Older: Network.getAllByName.
 */
internal class LocalResolver(private val platform: VpnPlatformInterface) : LocalDNSTransport {

    private companion object {
        const val RCODE_NXDOMAIN = 3
        const val TIMEOUT_SECONDS = 15L
    }

    private val directExecutor = Executor { it.run() }

    override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    private fun requireNetwork() =
        platform.currentNetwork() ?: throw IllegalStateException("android: no available network")

    @TargetApi(Build.VERSION_CODES.Q)
    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        val network = requireNetwork()
        val done = CountDownLatch(1)
        var failure: Exception? = null
        val signal = CancellationSignal()
        ctx.onCancel(Func {
            signal.cancel()
            done.countDown()
        })
        DnsResolver.getInstance().rawQuery(
            network,
            message,
            DnsResolver.FLAG_NO_RETRY,
            directExecutor,
            signal,
            object : DnsResolver.Callback<ByteArray> {
                override fun onAnswer(answer: ByteArray, rcode: Int) {
                    // The raw answer already carries its rcode.
                    ctx.rawSuccess(answer)
                    done.countDown()
                }

                override fun onError(error: DnsResolver.DnsException) {
                    val cause = error.cause
                    if (cause is ErrnoException) {
                        ctx.errnoCode(cause.errno)
                    } else {
                        failure = error
                    }
                    done.countDown()
                }
            },
        )
        if (!done.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            signal.cancel()
            throw IllegalStateException("android: dns query timed out")
        }
        failure?.let { throw it }
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        val underlying = requireNetwork()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            lookupQ(ctx, underlying, network, domain)
            return
        }
        val answer = try {
            underlying.getAllByName(domain)
        } catch (e: UnknownHostException) {
            ctx.errorCode(RCODE_NXDOMAIN)
            return
        }
        ctx.success(filter(answer.asList(), network))
    }

    @TargetApi(Build.VERSION_CODES.Q)
    private fun lookupQ(ctx: ExchangeContext, underlying: android.net.Network, network: String, domain: String) {
        val done = CountDownLatch(1)
        var failure: Exception? = null
        val signal = CancellationSignal()
        ctx.onCancel(Func {
            signal.cancel()
            done.countDown()
        })
        val callback = object : DnsResolver.Callback<List<InetAddress>> {
            override fun onAnswer(answer: List<InetAddress>, rcode: Int) {
                if (rcode == 0) {
                    ctx.success(filter(answer, network))
                } else {
                    ctx.errorCode(rcode)
                }
                done.countDown()
            }

            override fun onError(error: DnsResolver.DnsException) {
                val cause = error.cause
                if (cause is ErrnoException) {
                    ctx.errnoCode(cause.errno)
                } else {
                    failure = error
                }
                done.countDown()
            }
        }
        val type = when {
            network.endsWith("4") -> DnsResolver.TYPE_A
            network.endsWith("6") -> DnsResolver.TYPE_AAAA
            else -> null
        }
        if (type != null) {
            DnsResolver.getInstance().query(
                underlying, domain, type, DnsResolver.FLAG_NO_RETRY, directExecutor, signal, callback,
            )
        } else {
            DnsResolver.getInstance().query(
                underlying, domain, DnsResolver.FLAG_NO_RETRY, directExecutor, signal, callback,
            )
        }
        if (!done.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            signal.cancel()
            throw IllegalStateException("android: dns query timed out")
        }
        failure?.let { throw it }
    }

    private fun filter(addresses: List<InetAddress>, network: String): String =
        addresses.filter {
            when {
                network.endsWith("4") -> it is Inet4Address
                network.endsWith("6") -> it is Inet6Address
                else -> true
            }
        }.mapNotNull { it.hostAddress?.substringBefore('%') }.joinToString("\n")
}
