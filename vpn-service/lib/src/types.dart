/// Types shared by the Karing+ app and the vpn_service plugin.
library;

class VpnServiceResultError {
  VpnServiceResultError(this.message);
  String message;

  @override
  String toString() => message;
}

enum VpnServiceWaitType { done, timeout, error }

class VpnServiceWaitResult {
  VpnServiceWaitResult(this.type, [this.err]);
  VpnServiceWaitType type;
  VpnServiceResultError? err;
}

/// System proxy address set by [FlutterVpnService.setSystemProxy].
class ProxyOption {
  ProxyOption(this.host, this.port);
  String host;
  int port;
}

/// The service configuration the app writes before every start (service_config.json).
/// Field names match the JSON the app and the core service exchange.
// ignore_for_file: non_constant_identifier_names
class VpnServiceConfig {
  int control_port = 0;
  String base_dir = "";
  String work_dir = "";
  String cache_dir = "";
  String core_path = "";
  String log_path = "";
  String err_path = "";
  String id = "";
  String version = "";
  String name = "";
  String secret = "";
  String install_refer = "";
  int expired_time = 0;
  String time_connect = "";
  String time_disconnect = "";
  String sentry_minversion = "";

  Map<String, dynamic> toJson() => {
        'control_port': control_port,
        'base_dir': base_dir,
        'work_dir': work_dir,
        'cache_dir': cache_dir,
        'core_path': core_path,
        'log_path': log_path,
        'err_path': err_path,
        'id': id,
        'version': version,
        'name': name,
        'secret': secret,
        'install_refer': install_refer,
        'expired_time': expired_time,
        'time_connect': time_connect,
        'time_disconnect': time_disconnect,
        'sentry_minversion': sentry_minversion,
      };

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) return;
    control_port = map['control_port'] ?? 0;
    base_dir = map['base_dir'] ?? "";
    work_dir = map['work_dir'] ?? "";
    cache_dir = map['cache_dir'] ?? "";
    core_path = map['core_path'] ?? "";
    log_path = map['log_path'] ?? "";
    err_path = map['err_path'] ?? "";
    id = map['id'] ?? "";
    version = map['version'] ?? "";
    name = map['name'] ?? "";
    secret = map['secret'] ?? "";
    install_refer = map['install_refer'] ?? "";
    expired_time = map['expired_time'] ?? 0;
    time_connect = map['time_connect'] ?? "";
    time_disconnect = map['time_disconnect'] ?? "";
    sentry_minversion = map['sentry_minversion'] ?? "";
  }
}

/// Arguments of the last [FlutterVpnService.prepareConfig] call.
class PreparedConfig {
  PreparedConfig({
    required this.config,
    required this.tunnelServicePath,
    required this.configFilePath,
    required this.excludePorts,
  });
  final VpnServiceConfig config;
  final String tunnelServicePath;
  final String configFilePath;
  final List<int> excludePorts;
}

/// State of the built-in zapret backend (Windows). [token] authorizes calls to it.
class ZapretInfo {
  ZapretInfo({required this.running, required this.port, required this.token});
  final bool running;
  final int port;
  final String token;
}
