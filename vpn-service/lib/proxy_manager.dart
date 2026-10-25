/// macOS network-device exclusion. Karing+ does not target macOS, so this keeps the call site compiling.
class ProxyManager {
  void setExcludeDevices(Set<String> devices) {}
}
