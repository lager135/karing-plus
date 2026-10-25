/// Connection state of the VPN core.
///
/// The names must stay exactly as they are: the Karing+ app compares against
/// these values. Native code sends the lower-case name of the state.
enum FlutterVpnServiceState {
  connected,
  connecting,
  disconnected,
  disconnecting,
  invalid,
  reasserting,
}
