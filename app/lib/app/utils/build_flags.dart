/// Karing+ build switches (set with --dart-define).
abstract final class BuildFlags {
  /// Test builds: verbose core log, developer mode and a log-sharing button.
  /// Build with --dart-define=KARINGPLUS_DEBUG=true; release builds leave it off.
  static const bool debug = bool.fromEnvironment("KARINGPLUS_DEBUG");
}
