// Karing+: Wi-Fi hotspot tab (Windows Mobile Hotspot).
//
// The hotspot shares one connection of this PC. With the VPN connected the Karing+ tunnel can be shared,
// so devices on the hotspot go through the VPN; otherwise the normal network (Wi-Fi/Ethernet) is shared.
// The work is done by windows/hotspot/hotspot.ps1 (WinRT NetworkOperatorTetheringManager) next to the app.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/utils/path_utils.dart';
import 'package:karing/screens/qrcode_screen.dart';
import 'package:path/path.dart' as path;

String _tr(String ru, String en) =>
    SettingManager.getConfig().languageTag.startsWith("ru") ? ru : en;

class HotspotState {
  bool ok = false;
  String error = "";
  String state = "Off";
  String ssid = "";
  String pass = "";
  String band = "auto";
  int clients = 0;
  int maxClients = 0;
  String source = "";

  bool get on => state == "On" || state == "InTransition";

  static HotspotState fromJson(Map<String, dynamic> m) => HotspotState()
    ..ok = m["ok"] == true
    ..error = "${m["error"] ?? ""}"
    ..state = "${m["state"] ?? "Off"}"
    ..ssid = "${m["ssid"] ?? ""}"
    ..pass = "${m["pass"] ?? ""}"
    ..band = "${m["band"] ?? "auto"}"
    ..clients = (m["clients"] as num?)?.toInt() ?? 0
    ..maxClients = (m["maxClients"] as num?)?.toInt() ?? 0
    ..source = "${m["source"] ?? ""}";
}

class Hotspot {
  static String _script() =>
      path.join(PathUtils.exeDir(), "hotspot", "hotspot.ps1");

  static Future<Map<String, dynamic>> _run(List<String> args) async {
    final r = await Process.run("powershell.exe", [
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      _script(),
      ...args,
    ], stdoutEncoding: utf8, stderrEncoding: utf8)
        .timeout(const Duration(seconds: 60));
    final text = "${r.stdout}".trim();
    final line = text.split("\n").lastWhere((l) => l.trim().startsWith("{"),
        orElse: () => "");
    if (line.isEmpty) {
      return {"ok": false, "error": "${r.stderr}".trim()};
    }
    return (jsonDecode(line) as Map).cast<String, dynamic>();
  }

  static Future<HotspotState> status(String source) async =>
      HotspotState.fromJson(await _run(
          ["-Action", "status", if (source.isNotEmpty) ...["-Source", source]]));

  static Future<HotspotState> configure(
          String source, String ssid, String pass, String band) async =>
      HotspotState.fromJson(await _run([
        "-Action",
        "configure",
        if (source.isNotEmpty) ...["-Source", source],
        "-Ssid",
        ssid,
        "-Pass",
        pass,
        "-Band",
        band,
      ]));

  static Future<HotspotState> setOn(String source, bool on) async =>
      HotspotState.fromJson(await _run([
        "-Action",
        on ? "start" : "stop",
        if (source.isNotEmpty) ...["-Source", source],
      ]));

  /// Connections that can be shared: name and connectivity level.
  static Future<(List<String>, String)> profiles() async {
    final m = await _run(["-Action", "profiles"]);
    final list = ((m["profiles"] as List?) ?? [])
        .map((e) => "${(e as Map)["name"]}")
        .toList();
    return (list, "${m["internet"] ?? ""}");
  }

  /// Text of a Wi-Fi QR code (WIFI:T:WPA;S:<ssid>;P:<pass>;;) with the special characters escaped.
  static String qr(String ssid, String pass) {
    String esc(String s) => s.replaceAllMapped(
        RegExp(r'([\\;,:"])'), (m) => '\\${m.group(1)}');
    return "WIFI:T:WPA;S:${esc(ssid)};P:${esc(pass)};;";
  }
}

class HotspotScreen extends StatefulWidget {
  static RouteSettings routSettings() =>
      const RouteSettings(name: "HotspotScreen");

  const HotspotScreen({super.key});

  @override
  State<HotspotScreen> createState() => _HotspotScreenState();
}

class _HotspotScreenState extends State<HotspotScreen> {
  final _ssid = TextEditingController();
  final _pass = TextEditingController();
  String _band = "auto";
  bool _showPass = false;
  bool _busy = true;
  HotspotState _st = HotspotState();
  List<String> _profiles = [];
  String _source = "";

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ssid.dispose();
    _pass.dispose();
    super.dispose();
  }

  /// The Karing+ tunnel when it is up, otherwise the current internet connection.
  String _preferredSource(List<String> list, String internet) {
    final saved = SettingManager.getConfig().hotspotSource;
    if (saved.isNotEmpty && list.contains(saved)) return saved;
    final tun = list.firstWhere((n) => n.toLowerCase().contains("karing"),
        orElse: () => "");
    return tun.isNotEmpty ? tun : internet;
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final (list, internet) = await Hotspot.profiles();
      _profiles = list;
      _source = _preferredSource(list, internet);
      _st = await Hotspot.status(_source);
      _ssid.text = _st.ssid;
      _pass.text = _st.pass;
      _band = _st.band;
    } catch (e) {
      _st = HotspotState()..error = e.toString();
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _apply({bool? turnOn}) async {
    final ssid = _ssid.text.trim();
    final pass = _pass.text;
    if (ssid.isEmpty || ssid.length > 32) {
      _snack(_tr("Имя сети: от 1 до 32 символов", "Network name: 1 to 32 characters"));
      return;
    }
    if (pass.length < 8 || pass.length > 63) {
      _snack(_tr("Пароль: от 8 до 63 символов", "Password: 8 to 63 characters"));
      return;
    }
    setState(() => _busy = true);
    SettingManager.getConfig().hotspotSource = _source;
    SettingManager.setDirty(true);
    var st = await Hotspot.configure(_source, ssid, pass, _band);
    if (st.ok && turnOn != null) {
      // A new source or settings take effect on the next start.
      if (turnOn && _st.on) await Hotspot.setOn(_source, false);
      st = await Hotspot.setOn(_source, turnOn);
    }
    if (!st.ok) _snack(st.error);
    await _load();
  }

  void _snack(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  @override
  Widget build(BuildContext context) {
    final on = _st.on;
    return Scaffold(
      appBar: AppBar(
        title: Text(_tr("Раздача Wi-Fi", "Wi-Fi hotspot")),
        actions: [
          IconButton(
              onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            if (_busy) const LinearProgressIndicator(),
            Card(
              child: SwitchListTile(
                secondary: Icon(on ? Icons.wifi_tethering : Icons.portable_wifi_off,
                    color: on ? Colors.green : null),
                title: Text(on
                    ? _tr("Раздача включена", "Hotspot is on")
                    : _tr("Раздача выключена", "Hotspot is off")),
                subtitle: Text(on
                    ? _tr("Клиентов: ${_st.clients} из ${_st.maxClients}",
                        "Clients: ${_st.clients} of ${_st.maxClients}")
                    : (_st.error.isNotEmpty ? _st.error : _tr(
                        "Источник: ${_st.source}", "Source: ${_st.source}"))),
                value: on,
                onChanged: _busy ? null : (v) => _apply(turnOn: v),
              ),
            ),
            const SizedBox(height: 12),
            Text(_tr("Что раздавать", "What to share"),
                style: Theme.of(context).textTheme.titleMedium),
            DropdownButton<String>(
              isExpanded: true,
              value: _profiles.contains(_source) ? _source : null,
              items: _profiles
                  .map((p) => DropdownMenuItem(
                      value: p,
                      child: Text(p.toLowerCase().contains("karing")
                          ? _tr("$p — через VPN Karing+", "$p — through the Karing+ VPN")
                          : p)))
                  .toList(),
              onChanged: _busy ? null : (v) => setState(() => _source = v ?? ""),
            ),
            Text(
              _tr(
                  "Чтобы устройства на раздаче шли через VPN, подключите VPN и выберите туннель Karing+. "
                      "Для режима Zapret раздавайте обычную сеть (Wi-Fi или Ethernet).",
                  "To send hotspot devices through the VPN, connect the VPN and pick the Karing+ tunnel. "
                      "For Zapret mode share the normal network (Wi-Fi or Ethernet)."),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ssid,
              maxLength: 32,
              decoration: InputDecoration(
                  labelText: _tr("Имя сети (SSID)", "Network name (SSID)"),
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _pass,
              obscureText: !_showPass,
              maxLength: 63,
              decoration: InputDecoration(
                labelText: _tr("Пароль (8–63 символа)", "Password (8–63 characters)"),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPass = !_showPass),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(_tr("Диапазон", "Band"),
                style: Theme.of(context).textTheme.titleSmall),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: "auto", label: Text(_tr("Авто", "Auto"))),
                const ButtonSegment(value: "2.4", label: Text("2.4 GHz")),
                const ButtonSegment(value: "5", label: Text("5 GHz")),
              ],
              selected: {_band},
              onSelectionChanged:
                  _busy ? null : (s) => setState(() => _band = s.first),
            ),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: _busy ? null : () => _apply(turnOn: on ? true : null),
                icon: const Icon(Icons.save),
                label: Text(on
                    ? _tr("Сохранить и перезапустить", "Save and restart")
                    : _tr("Сохранить", "Save")),
              ),
              if (on)
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              settings: QrcodeScreen.routSettings(),
                              builder: (context) => QrcodeScreen(
                                  content: Hotspot.qr(_st.ssid, _st.pass)))),
                  icon: const Icon(Icons.qr_code_2),
                  label: Text(_tr("Поделиться QR", "Share QR")),
                ),
            ]),
          ]),
        ),
      ),
    );
  }
}
