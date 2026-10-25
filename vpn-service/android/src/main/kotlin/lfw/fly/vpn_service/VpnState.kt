package lfw.fly.vpn_service

/** Core state. Dart receives the lower-case name. */
enum class VpnState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    DISCONNECTING,
    REASSERTING,
    INVALID,
}

/** Receives every state change. Called on the thread that changed the state. */
fun interface VpnStateListener {
    fun onStateChanged(state: VpnState, error: String?)
}
