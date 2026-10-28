import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'src/karing_compat.dart';
import 'src/linux_backend.dart';
import 'src/types.dart';
import 'src/windows_backend.dart';
import 'state.dart';

export 'src/types.dart';
export 'state.dart';

const String _methodChannelName = 'lfw.fly.vpn_service/methods';
const String _stateChannelName = 'lfw.fly.vpn_service/state';

FlutterVpnServiceState _parseState(Object? raw) {
  if (raw is String) {
    for (final state in FlutterVpnServiceState.values) {
      if (state.name == raw) return state;
    }
  }
  return FlutterVpnServiceState.invalid;
}

/// Entry point used by the Karing+ app. All members are static.
///
/// Windows: the core runs in karingService.exe (a Windows service), see [WindowsBackend].
/// Linux: see [LinuxBackend] (core service under systemd).
/// Android: the core runs in the plugin's VpnService (libbox) over the method channel.
class FlutterVpnService {
  FlutterVpnService._();

  static const MethodChannel _methods = MethodChannel(_methodChannelName);
  static const EventChannel _states = EventChannel(_stateChannelName);
  static StreamSubscription? _androidSub;
  static final List<
          void Function(FlutterVpnServiceState state, Map<String, String> params)>
      _androidListeners = [];
  static PreparedConfig? _prepared;

  // --- state ---------------------------------------------------------------

  static void onStateChanged(
      void Function(FlutterVpnServiceState state, Map<String, String> params)
          callback) {
    if (Platform.isWindows) {
      WindowsBackend.addListener(callback);
      return;
    }
    if (Platform.isLinux) {
      LinuxBackend.addListener(callback);
      return;
    }
    if (Platform.isAndroid) {
      _androidListeners.add(callback);
      _androidSub ??= _states.receiveBroadcastStream().listen((raw) {
        final s = _parseState(raw);
        for (final cb in List.of(_androidListeners)) {
          cb(s, const {});
        }
      });
    }
  }

  static Future<FlutterVpnServiceState> get currentState async {
    if (Platform.isWindows) return WindowsBackend.currentState();
    if (Platform.isLinux) return LinuxBackend.currentState();
    try {
      return _parseState(await _methods.invokeMethod<String>('getState'));
    } on MissingPluginException {
      return FlutterVpnServiceState.disconnected;
    }
  }

  // --- config --------------------------------------------------------------

  static void prepareConfig({
    required VpnServiceConfig config,
    required String tunnelServicePath,
    required String configFilePath,
    bool systemExtension = false,
    String bundleIdentifier = "",
    String uiServerAddress = "",
    String uiLocalizedDescription = "",
    List<int> excludePorts = const [],
  }) {
    _prepared = PreparedConfig(
      config: config,
      tunnelServicePath: tunnelServicePath,
      configFilePath: configFilePath,
      excludePorts: excludePorts,
    );
  }

  // --- core ----------------------------------------------------------------

  static Future<VpnServiceResultError?> installService() async {
    if (Platform.isWindows) {
      final path = _prepared?.tunnelServicePath;
      if (path == null) {
        return VpnServiceResultError('prepareConfig was not called');
      }
      return WindowsBackend.installService(path);
    }
    if (Platform.isLinux && _prepared != null) {
      return LinuxBackend.installService(_prepared!.tunnelServicePath);
    }
    return null;
  }

  /// The app calls this after every disconnect on Windows. The service stays installed so the
  /// next connect needs no UAC prompt; [removeService] really removes it.
  static Future<VpnServiceResultError?> uninstallService() async => null;

  static Future<VpnServiceResultError?> removeService() async {
    if (Platform.isWindows && _prepared != null) {
      return WindowsBackend.removeService(_prepared!.tunnelServicePath);
    }
    if (Platform.isLinux && _prepared != null) {
      return LinuxBackend.removeService(_prepared!.tunnelServicePath);
    }
    return null;
  }

  static Future<VpnServiceWaitResult> start(Duration timeout) async {
    if (Platform.isWindows) return WindowsBackend.start(_prepared, timeout);
    if (Platform.isLinux) return LinuxBackend.start(_prepared, timeout);
    return _androidCore('start', timeout);
  }

  static Future<VpnServiceWaitResult> restart(Duration timeout) async {
    await stop();
    return start(timeout);
  }

  static Future<VpnServiceResultError?> reload() async {
    final r = await restart(const Duration(seconds: 30));
    if (r.type == VpnServiceWaitType.done) return null;
    return r.err ?? VpnServiceResultError('reload timeout');
  }

  static Future<void> stop() async {
    if (Platform.isWindows) return WindowsBackend.stop();
    if (Platform.isLinux) return LinuxBackend.stop();
    try {
      await _methods.invokeMethod<String>('stop', {'timeoutMs': 15000});
    } on MissingPluginException {
      return;
    }
  }

  static Future<VpnServiceWaitResult> _androidCore(
      String method, Duration timeout) async {
    final prepared = _prepared;
    if (prepared == null) {
      return VpnServiceWaitResult(VpnServiceWaitType.error,
          VpnServiceResultError('prepareConfig was not called'));
    }
    try {
      final granted = await _methods.invokeMethod<bool>('prepare') ?? false;
      if (!granted) {
        return VpnServiceWaitResult(VpnServiceWaitType.error,
            VpnServiceResultError('VPN permission was not granted'));
      }
      var config = normalizeKaringConfig(
          await File(prepared.config.core_path).readAsString());
      String? error;
      for (var i = 0; i < 50; i++) {
        error = await _methods.invokeMethod<String>(method, {
          'config': config,
          'timeoutMs': timeout.inMilliseconds,
        }).timeout(timeout + const Duration(seconds: 5));
        if (error == null) break;
        // A field only Karing's own core knows: drop it and try again.
        final next = dropUnknownField(config, error);
        if (next == null) break;
        config = next;
      }
      if (error == null) return VpnServiceWaitResult(VpnServiceWaitType.done);
      return VpnServiceWaitResult(
          VpnServiceWaitType.error, VpnServiceResultError(error));
    } on TimeoutException {
      return VpnServiceWaitResult(VpnServiceWaitType.timeout);
    } on PlatformException catch (e) {
      return VpnServiceWaitResult(VpnServiceWaitType.error,
          VpnServiceResultError(e.message ?? e.code));
    } on MissingPluginException {
      return VpnServiceWaitResult(VpnServiceWaitType.error,
          VpnServiceResultError('vpn_service is not available on this platform'));
    }
  }

  // --- zapret (Windows: winws, Linux: nfqws) -------------------------------------

  /// Starts or stops the bundled zapret backend through the core service.
  /// [servicePath] is the core service binary next to the app.
  static Future<VpnServiceResultError?> zapretSet(
      String servicePath, bool enable) async {
    if (Platform.isWindows) return WindowsBackend.zapretSet(servicePath, enable);
    if (Platform.isLinux) return LinuxBackend.zapretSet(servicePath, enable);
    return VpnServiceResultError('zapret is available on Windows and Linux only');
  }

  static Future<bool> zapretRunning() async {
    if (Platform.isWindows) return WindowsBackend.zapretRunning();
    if (Platform.isLinux) return LinuxBackend.zapretRunning();
    return false;
  }

  static Future<ZapretInfo?> zapretInfo() async {
    if (Platform.isWindows) return WindowsBackend.zapretInfo();
    if (Platform.isLinux) return LinuxBackend.zapretInfo();
    return null;
  }

  // --- system proxy (Windows) -----------------------------------------------

  static Future<void> setSystemProxy(ProxyOption option) async {
    if (Platform.isWindows) await WindowsBackend.setSystemProxy(option);
    if (Platform.isLinux) await LinuxBackend.setSystemProxy(option);
  }

  static Future<bool> getSystemProxyEnable(ProxyOption option) async {
    if (Platform.isWindows) return WindowsBackend.getSystemProxyEnable(option);
    if (Platform.isLinux) return LinuxBackend.getSystemProxyEnable(option);
    return false;
  }

  static Future<void> cleanSystemProxy() async {
    if (Platform.isWindows) await WindowsBackend.cleanSystemProxy();
    if (Platform.isLinux) await LinuxBackend.cleanSystemProxy();
  }

  // --- platform helpers -------------------------------------------------------

  static Future<bool> isRunAsAdmin() async {
    if (Platform.isWindows) return WindowsBackend.isRunAsAdmin();
    if (Platform.isLinux) return LinuxBackend.isRunAsAdmin();
    return false;
  }

  /// Firewall rules need admin rights. The TUN core runs in the service, so the app adds none.
  static Future<void> firewallAddApp(String path, String name) async {}
  static Future<void> firewallAddPorts(List<int> ports, String name) async {}

  static Future<void> autoStartCreate(String name, String exe,
      {String processArgs = "", bool runElevated = false}) async {
    if (Platform.isWindows) {
      await WindowsBackend.autoStartCreate(name, exe,
          processArgs: processArgs, runElevated: runElevated);
    }
    if (Platform.isLinux) {
      await LinuxBackend.autoStartCreate(name, exe,
          processArgs: processArgs, runElevated: runElevated);
    }
  }

  static Future<void> autoStartDelete(String name) async {
    if (Platform.isWindows) await WindowsBackend.autoStartDelete(name);
    if (Platform.isLinux) await LinuxBackend.autoStartDelete(name);
  }

  static Future<bool> autoStartIsActive(String name) async {
    if (Platform.isWindows) return WindowsBackend.autoStartIsActive(name);
    if (Platform.isLinux) return LinuxBackend.autoStartIsActive(name);
    return false;
  }

  static Future<String> getABIs() async {
    if (!Platform.isAndroid) return "";
    try {
      return await _methods.invokeMethod<String>('getABIs') ?? "";
    } on MissingPluginException {
      return "";
    }
  }

  static Future<String> getSystemVersion() async {
    if (Platform.isAndroid) {
      try {
        return await _methods.invokeMethod<String>('getSystemVersion') ??
            Platform.operatingSystemVersion;
      } on MissingPluginException {
        return Platform.operatingSystemVersion;
      }
    }
    return Platform.operatingSystemVersion;
  }

  static Future<void> setAlwaysOn(bool value) async {
    if (!Platform.isAndroid) return;
    try {
      await _methods.invokeMethod<void>('setAlwaysOn', {'value': value});
    } on MissingPluginException {
      return;
    }
  }

  /// Where the app keeps its profile. Windows: %APPDATA%\KaringPlus (separate from upstream Karing).
  /// Android: the app's private support directory.
  static Future<Directory?> getAppGroupDirectory(String groupId) async {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData == null || appData.isEmpty) return null;
      return Directory(p.join(appData, 'KaringPlus'));
    }
    if (Platform.isLinux) {
      // Linux: ~/.local/share/KaringPlus (separate from upstream Karing).
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return null;
      return Directory(p.join(home, '.local', 'share', 'KaringPlus'));
    }
    try {
      return await getApplicationSupportDirectory();
    } catch (_) {
      return null;
    }
  }

  /// macOS only.
  static Future<String?> getProcessList() async => null;

  /// macOS only.
  static Future<Uint8List?> getProcessIcon(String identifier) async => null;
}
