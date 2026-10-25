import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../state.dart';
import 'types.dart';

/// Windows side of the plugin. The core runs inside karingService.exe, a Windows service
/// (LocalSystem), so the sing-box TUN inbound can create the wintun adapter while the app
/// runs as a normal user. The service is installed once through a UAC prompt; after that
/// connect and disconnect need no elevation. The app controls it over 127.0.0.1 with a
/// bearer secret that only this Windows user can read.
class WindowsBackend {
  static const _base = 'http://127.0.0.1:44781';
  static const _internetSettings =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static const _proxyBypass =
      '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.2*;172.30.*;172.31.*;192.168.*';

  static FlutterVpnServiceState _state = FlutterVpnServiceState.disconnected;
  static final List<void Function(FlutterVpnServiceState, Map<String, String>)>
      _listeners = [];
  static Timer? _watch;
  static String? _secret;

  static void addListener(
      void Function(FlutterVpnServiceState, Map<String, String>) cb) {
    _listeners.add(cb);
  }

  static void _set(FlutterVpnServiceState s, [Map<String, String>? params]) {
    if (_state == s) return;
    _state = s;
    for (final cb in List.of(_listeners)) {
      cb(s, params ?? const {});
    }
  }

  // --- secret -------------------------------------------------------------

  static String _secretPath() {
    final base = Platform.environment['LOCALAPPDATA'] ??
        p.join(Platform.environment['USERPROFILE'] ?? '.', 'AppData', 'Local');
    return p.join(base, 'KaringPlus', 'service.secret');
  }

  static Future<String> _loadSecret({bool regenerate = false}) async {
    if (_secret != null && !regenerate) return _secret!;
    final f = File(_secretPath());
    if (!regenerate && await f.exists()) {
      final s = (await f.readAsString()).trim();
      if (RegExp(r'^[0-9a-f]{64}$').hasMatch(s)) return _secret = s;
    }
    final rnd = Random.secure();
    final s = List.generate(32, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await f.parent.create(recursive: true);
    await f.writeAsString(s, flush: true);
    return _secret = s;
  }

  // --- HTTP to the service --------------------------------------------------

  static Future<(int, Map<String, dynamic>)> _call(String method, String path,
      {String? body, Duration timeout = const Duration(seconds: 5)}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    // The service is on loopback; never send this through a system proxy.
    client.findProxy = (_) => 'DIRECT';
    try {
      final req = await client.openUrl(method, Uri.parse('$_base$path'));
      req.headers.set('Authorization', 'Bearer ${await _loadSecret()}');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(body));
      }
      final resp = await req.close().timeout(timeout);
      final text = await resp.transform(utf8.decoder).join().timeout(timeout);
      Map<String, dynamic> data = {};
      try {
        data = (jsonDecode(text) as Map).cast<String, dynamic>();
      } catch (_) {}
      return (resp.statusCode, data);
    } finally {
      client.close(force: true);
    }
  }

  /// true when the service answers and accepts our secret.
  static Future<bool> _serviceReady() async {
    try {
      final (code, _) = await _call('GET', '/state');
      return code == 200;
    } catch (_) {
      return false;
    }
  }

  // --- install --------------------------------------------------------------

  static Future<VpnServiceResultError?> installService(String servicePath) async {
    if (await _serviceReady()) return null;
    if (!await File(servicePath).exists()) {
      return VpnServiceResultError('core service not found: $servicePath');
    }
    // New secret for this install; handed over in a file so it never appears on a command line.
    final secret = await _loadSecret(regenerate: true);
    final tmp = File(p.join(Directory.systemTemp.path,
        'karingplus-${DateTime.now().microsecondsSinceEpoch}.secret'));
    await tmp.writeAsString(secret, flush: true);
    try {
      String q(String s) => "'${s.replaceAll("'", "''")}'";
      final script = 'Start-Process -FilePath ${q(servicePath)} '
          '-ArgumentList @(\'install\',\'-secret-file\',${q('"${tmp.path}"')}) '
          '-Verb RunAs -WindowStyle Hidden -Wait';
      final r = await Process.run(
          'powershell', ['-NoProfile', '-NonInteractive', '-Command', script]);
      if (r.exitCode != 0) {
        return VpnServiceResultError(
            'service install was cancelled or failed: ${r.stderr}'.trim());
      }
    } finally {
      try {
        await tmp.delete();
      } catch (_) {}
    }
    for (var i = 0; i < 30; i++) {
      if (await _serviceReady()) return null;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return VpnServiceResultError('core service did not start');
  }

  /// Removes the service (UAC prompt). Not called on every disconnect: the service stays installed.
  static Future<VpnServiceResultError?> removeService(String servicePath) async {
    String q(String s) => "'${s.replaceAll("'", "''")}'";
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Start-Process -FilePath ${q(servicePath)} -ArgumentList uninstall -Verb RunAs -WindowStyle Hidden -Wait'
    ]);
    return r.exitCode == 0 ? null : VpnServiceResultError('${r.stderr}'.trim());
  }

  // --- core -----------------------------------------------------------------

  static Future<VpnServiceWaitResult> start(
      PreparedConfig? prepared, Duration timeout) async {
    if (prepared == null) {
      return VpnServiceWaitResult(VpnServiceWaitType.error,
          VpnServiceResultError('prepareConfig was not called'));
    }
    final err = await installService(prepared.tunnelServicePath);
    if (err != null) {
      return VpnServiceWaitResult(VpnServiceWaitType.error, err);
    }
    final core = File(prepared.config.core_path);
    if (!await core.exists()) {
      return VpnServiceWaitResult(VpnServiceWaitType.error,
          VpnServiceResultError('core config not found'));
    }
    _set(FlutterVpnServiceState.connecting);
    try {
      final (code, data) = await _call('POST', '/start',
          body: await core.readAsString(), timeout: timeout);
      if (code != 200) {
        _set(FlutterVpnServiceState.disconnected);
        final msg = (data['error'] ?? 'core start failed ($code)').toString();
        await _writeError(prepared.config.err_path, msg);
        return VpnServiceWaitResult(
            VpnServiceWaitType.error, VpnServiceResultError(msg));
      }
    } on TimeoutException {
      _set(FlutterVpnServiceState.disconnected);
      return VpnServiceWaitResult(VpnServiceWaitType.timeout);
    } catch (e) {
      _set(FlutterVpnServiceState.disconnected);
      return VpnServiceWaitResult(
          VpnServiceWaitType.error, VpnServiceResultError(e.toString()));
    }
    _set(FlutterVpnServiceState.connected);
    _startWatch();
    return VpnServiceWaitResult(VpnServiceWaitType.done);
  }

  static Future<void> _writeError(String path, String msg) async {
    if (path.isEmpty) return;
    try {
      await File(path).writeAsString(msg, flush: true);
    } catch (_) {}
  }

  static Future<void> stop() async {
    _watch?.cancel();
    _watch = null;
    if (_state == FlutterVpnServiceState.connected) {
      _set(FlutterVpnServiceState.disconnecting);
    }
    try {
      await _call('POST', '/stop', timeout: const Duration(seconds: 15));
    } catch (_) {}
    _set(FlutterVpnServiceState.disconnected);
  }

  /// Follows the core while connected, so a crash shows as a disconnect in the app.
  static void _startWatch() {
    _watch?.cancel();
    _watch = Timer.periodic(const Duration(seconds: 2), (_) async {
      final s = await currentState();
      if (s != FlutterVpnServiceState.connected) {
        _watch?.cancel();
        _watch = null;
        _set(FlutterVpnServiceState.disconnected);
      }
    });
  }

  static Future<FlutterVpnServiceState> currentState() async {
    try {
      final (code, data) = await _call('GET', '/state');
      if (code == 200 && data['state'] == 'connected') {
        return FlutterVpnServiceState.connected;
      }
    } catch (_) {}
    if (_state == FlutterVpnServiceState.connecting ||
        _state == FlutterVpnServiceState.disconnecting) {
      return _state;
    }
    return FlutterVpnServiceState.disconnected;
  }

  // --- zapret (DPI bypass) ------------------------------------------------------

  static Future<VpnServiceResultError?> zapretSet(
      String servicePath, bool enable) async {
    final err = await installService(servicePath);
    if (err != null) return err;
    try {
      final (code, data) = await _call(
          'POST', enable ? '/zapret/start' : '/zapret/stop',
          timeout: const Duration(seconds: 20));
      if (code == 200) return null;
      return VpnServiceResultError((data['error'] ?? 'zapret error $code').toString());
    } catch (e) {
      return VpnServiceResultError(e.toString());
    }
  }

  static Future<bool> zapretRunning() async =>
      (await zapretInfo())?.running ?? false;

  /// Port and per-start token of the zapret backend, or null when the service does not answer.
  static Future<ZapretInfo?> zapretInfo() async {
    try {
      final (code, data) = await _call('GET', '/zapret/state');
      if (code != 200) return null;
      return ZapretInfo(
        running: data['running'] == true,
        port: int.tryParse('${data['port'] ?? ''}') ?? 0,
        token: '${data['token'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  // --- system proxy -----------------------------------------------------------

  static Future<String?> _regQuery(String name) async {
    final r = await Process.run('reg', ['query', _internetSettings, '/v', name]);
    if (r.exitCode != 0) return null;
    final m = RegExp('$name\\s+REG_\\w+\\s+(.*)').firstMatch('${r.stdout}');
    return m?.group(1)?.trim();
  }

  static Future<void> _regSet(String name, String type, String value) async {
    await Process.run(
        'reg', ['add', _internetSettings, '/v', name, '/t', type, '/d', value, '/f']);
  }

  static Future<void> setSystemProxy(ProxyOption o) async {
    await _regSet('ProxyServer', 'REG_SZ', '${o.host}:${o.port}');
    await _regSet('ProxyOverride', 'REG_SZ', _proxyBypass);
    await _regSet('ProxyEnable', 'REG_DWORD', '1');
  }

  static Future<bool> getSystemProxyEnable(ProxyOption o) async {
    final enable = await _regQuery('ProxyEnable');
    if (enable == null || !(enable == '0x1' || enable == '1')) return false;
    return await _regQuery('ProxyServer') == '${o.host}:${o.port}';
  }

  static Future<void> cleanSystemProxy() async {
    await _regSet('ProxyEnable', 'REG_DWORD', '0');
  }

  // --- misc -------------------------------------------------------------------

  static Future<bool> isRunAsAdmin() async {
    try {
      final r = await Process.run('net', ['session']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<void> autoStartCreate(String name, String exe,
      {String processArgs = '', bool runElevated = false}) async {
    final tr = processArgs.isEmpty ? '"$exe"' : '"$exe" $processArgs';
    await Process.run('schtasks', [
      '/create', '/f', '/sc', 'onlogon', '/tn', name, '/tr', tr,
      if (runElevated) ...['/rl', 'highest'],
    ]);
  }

  static Future<void> autoStartDelete(String name) async {
    await Process.run('schtasks', ['/delete', '/f', '/tn', name]);
  }

  static Future<bool> autoStartIsActive(String name) async {
    final r = await Process.run('schtasks', ['/query', '/tn', name]);
    return r.exitCode == 0;
  }
}
