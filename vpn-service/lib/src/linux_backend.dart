import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../state.dart';
import 'types.dart';

/// Linux side of the plugin. Same model as [WindowsBackend]: the core runs inside karingService,
/// a root systemd unit (karingplus.service), so the sing-box TUN inbound can create its interface
/// and routes while the app runs as a normal user. The service is installed once through a polkit
/// prompt (pkexec); after that connect and disconnect need no elevation. The app controls it over
/// 127.0.0.1 with a bearer secret that only this Linux user can read (mode 0600).
class LinuxBackend {
  static const _base = 'http://127.0.0.1:44781';
  static const _proxySchema = 'org.gnome.system.proxy';
  static const _proxyIgnoreHosts =
      "['localhost', '127.0.0.0/8', '::1', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']";

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

  // --- paths ------------------------------------------------------------------

  static String _home() => Platform.environment['HOME'] ?? '.';

  /// $XDG_CONFIG_HOME, or ~/.config.
  static String _configHome() {
    final x = Platform.environment['XDG_CONFIG_HOME'];
    if (x != null && x.isNotEmpty && p.isAbsolute(x)) return x;
    return p.join(_home(), '.config');
  }

  static String _secretPath() =>
      p.join(_configHome(), 'KaringPlus', 'service.secret');

  /// On Linux the app passes just the file name (PathUtils.serviceExePath() has no directory);
  /// resolve a relative path next to the app executable.
  static String _resolveServicePath(String servicePath) {
    if (servicePath.isEmpty || p.isAbsolute(servicePath)) return servicePath;
    return p.join(p.dirname(Platform.resolvedExecutable), servicePath);
  }

  static Future<void> _chmod(String mode, String path) async {
    try {
      await Process.run('chmod', [mode, path]);
    } catch (_) {}
  }

  /// Writes [content] to [path] so that only this user can read it (0600 before any data).
  static Future<void> _writePrivate(String path, String content) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await _chmod('700', f.parent.path);
    await f.writeAsString('', flush: true);
    await _chmod('600', path);
    await f.writeAsString(content, flush: true);
  }

  // --- secret -------------------------------------------------------------------

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
    await _writePrivate(f.path, s);
    return _secret = s;
  }

  // --- HTTP to the service --------------------------------------------------------

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

  /// The running service's version when it answers and accepts our secret, otherwise null.
  static Future<String?> _serviceVersion() async {
    try {
      final (code, data) = await _call('GET', '/version');
      if (code != 200) return null;
      return '${data['version'] ?? ''}';
    } catch (_) {
      return null;
    }
  }

  /// Version of the service binary shipped with the app (`karingService version`).
  static Future<String?> _bundledVersion(String servicePath) async {
    try {
      final r = await Process.run(servicePath, ['version'])
          .timeout(const Duration(seconds: 5));
      if (r.exitCode != 0) return null;
      return '${r.stdout}'.trim();
    } catch (_) {
      return null;
    }
  }

  // --- install ----------------------------------------------------------------------

  static Future<VpnServiceResultError?> installService(String servicePath) async {
    servicePath = _resolveServicePath(servicePath);
    final running = await _serviceVersion();
    if (running != null) {
      // Installed and our secret works. Reinstall only when the app ships a different service.
      final bundled = await _bundledVersion(servicePath);
      if (bundled == null || bundled.isEmpty || bundled == running) return null;
    }
    if (!await File(servicePath).exists()) {
      return VpnServiceResultError('core service not found: $servicePath');
    }
    // New secret for this install; handed over in a file so it never appears on a command line.
    final secret = await _loadSecret(regenerate: true);
    final tmp = p.join(_configHome(), 'KaringPlus',
        'install-${DateTime.now().microsecondsSinceEpoch}.secret');
    try {
      await _writePrivate(tmp, secret);
      final ProcessResult r;
      try {
        r = await Process.run(
            'pkexec', [servicePath, 'install', '-secret-file', tmp]);
      } on ProcessException catch (e) {
        return VpnServiceResultError(
            'pkexec (polkit) is required to install the core service: ${e.message}');
      }
      // pkexec: 126 = the prompt was dismissed, 127 = not authorized.
      if (r.exitCode == 126 || (r.exitCode == 127 && '${r.stderr}'.isEmpty)) {
        return VpnServiceResultError('service install was cancelled');
      }
      if (r.exitCode != 0) {
        return VpnServiceResultError(
            'service install failed: ${r.stderr}${r.stdout}'.trim());
      }
    } finally {
      try {
        await File(tmp).delete();
      } catch (_) {}
    }
    for (var i = 0; i < 30; i++) {
      if (await _serviceVersion() != null) return null;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return VpnServiceResultError('core service did not start');
  }

  /// Removes the service (polkit prompt). Not called on every disconnect: the service stays installed.
  static Future<VpnServiceResultError?> removeService(String servicePath) async {
    servicePath = _resolveServicePath(servicePath);
    try {
      final r = await Process.run('pkexec', [servicePath, 'uninstall']);
      return r.exitCode == 0
          ? null
          : VpnServiceResultError('${r.stderr}${r.stdout}'.trim());
    } on ProcessException catch (e) {
      return VpnServiceResultError(e.message);
    }
  }

  // --- core ---------------------------------------------------------------------------

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

  // --- zapret (DPI bypass, nfqws) -------------------------------------------------
  // Same API as on Windows: the service runs the zapret backend as root, the app talks to it
  // on 127.0.0.1 with the per-start token.

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

  // --- system proxy (GNOME gsettings; no-op elsewhere) -----------------------------------

  static bool? _gsettingsOk;

  static Future<bool> _hasGsettings() async {
    if (_gsettingsOk != null) return _gsettingsOk!;
    try {
      final r = await Process.run('gsettings', ['list-schemas']);
      _gsettingsOk = r.exitCode == 0 &&
          LineSplitter.split('${r.stdout}').contains(_proxySchema);
    } catch (_) {
      _gsettingsOk = false;
    }
    return _gsettingsOk!;
  }

  static Future<String?> _gget(String schema, String key) async {
    final r = await Process.run('gsettings', ['get', schema, key]);
    if (r.exitCode != 0) return null;
    return '${r.stdout}'.trim();
  }

  static Future<void> _gset(String schema, String key, String value) async {
    await Process.run('gsettings', ['set', schema, key, value]);
  }

  static String _unquote(String? v) {
    if (v == null) return '';
    if (v.length >= 2 && v.startsWith("'") && v.endsWith("'")) {
      return v.substring(1, v.length - 1);
    }
    return v;
  }

  static Future<void> setSystemProxy(ProxyOption o) async {
    if (!await _hasGsettings()) return;
    for (final proto in ['http', 'https']) {
      await _gset('$_proxySchema.$proto', 'host', o.host);
      await _gset('$_proxySchema.$proto', 'port', '${o.port}');
    }
    await _gset(_proxySchema, 'ignore-hosts', _proxyIgnoreHosts);
    await _gset(_proxySchema, 'mode', 'manual');
  }

  static Future<bool> getSystemProxyEnable(ProxyOption o) async {
    if (!await _hasGsettings()) return false;
    try {
      if (_unquote(await _gget(_proxySchema, 'mode')) != 'manual') return false;
      final host = _unquote(await _gget('$_proxySchema.http', 'host'));
      final port = (await _gget('$_proxySchema.http', 'port'))?.trim();
      return host == o.host && port == '${o.port}';
    } catch (_) {
      return false;
    }
  }

  static Future<void> cleanSystemProxy() async {
    if (!await _hasGsettings()) return;
    await _gset(_proxySchema, 'mode', 'none');
  }

  // --- misc -----------------------------------------------------------------------------

  static Future<bool> isRunAsAdmin() async {
    try {
      final r = await Process.run('id', ['-u']);
      return r.exitCode == 0 && '${r.stdout}'.trim() == '0';
    } catch (_) {
      return false;
    }
  }

  static String _autostartPath(String name) {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return p.join(_configHome(), 'autostart', '$safe.desktop');
  }

  /// Quotes one argument for the Exec key of a .desktop file (Desktop Entry Specification).
  static String _execQuote(String s) {
    if (s.isNotEmpty && RegExp(r'^[A-Za-z0-9_./=:+,@-]+$').hasMatch(s)) return s;
    final escaped =
        s.replaceAllMapped(RegExp(r'["`$\\]'), (m) => '\\${m.group(0)}');
    return '"$escaped"';
  }

  /// [runElevated] has no meaning here: the core already runs in the root service.
  static Future<void> autoStartCreate(String name, String exe,
      {String processArgs = '', bool runElevated = false}) async {
    final exec = processArgs.isEmpty
        ? _execQuote(exe)
        : '${_execQuote(exe)} ${processArgs.replaceAll('%', '%%')}';
    final f = File(_autostartPath(name));
    await f.parent.create(recursive: true);
    await f.writeAsString(
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=${name.replaceAll('\n', ' ')}\n'
        'Exec=${exec.replaceAll('\n', ' ')}\n'
        'Terminal=false\n'
        'X-GNOME-Autostart-enabled=true\n',
        flush: true);
  }

  static Future<void> autoStartDelete(String name) async {
    try {
      await File(_autostartPath(name)).delete();
    } catch (_) {}
  }

  static Future<bool> autoStartIsActive(String name) async {
    final f = File(_autostartPath(name));
    if (!await f.exists()) return false;
    try {
      final text = await f.readAsString();
      return !RegExp(r'^Hidden\s*=\s*true', multiLine: true).hasMatch(text) &&
          !RegExp(r'^X-GNOME-Autostart-enabled\s*=\s*false', multiLine: true)
              .hasMatch(text);
    } catch (_) {
      return false;
    }
  }
}
