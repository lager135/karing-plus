// Karing+: built-in zapret (DPI bypass) tab.
//
// The zapret backend runs inside karingService.exe (SYSTEM rights, needed by winws). This screen talks
// to it directly on 127.0.0.1 with the per-start token the service hands to the app.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/utils/path_utils.dart';
import 'package:vpn_service/vpn_service.dart';

String _tr(String ru, String en) =>
    SettingManager.getConfig().languageTag.startsWith("ru") ? ru : en;

/// Small client for the zapret backend API.
class ZapretApi {
  ZapretApi(this.port, this.token);
  final int port;
  final String token;

  Future<dynamic> _req(String method, String path,
      {Object? body, Duration timeout = const Duration(seconds: 15)}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    client.findProxy = (_) => 'DIRECT';
    try {
      final req =
          await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
      req.headers.set('X-Zapret-Token', token);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final resp = await req.close().timeout(timeout);
      final text = await resp.transform(utf8.decoder).join().timeout(timeout);
      if (resp.statusCode != 200) {
        throw HttpException('zapret ${resp.statusCode}: $text');
      }
      return text.isEmpty ? null : jsonDecode(text);
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> status() async =>
      (await _req('GET', '/api/status') as Map).cast<String, dynamic>();
  Future<Map<String, dynamic>> start(String strategy) async =>
      (await _req('POST', '/api/start', body: {'strategy': strategy}) as Map)
          .cast<String, dynamic>();
  Future<void> stop() => _req('POST', '/api/stop');
  Future<List<String>> hostlist() async =>
      ((await _req('GET', '/api/hostlist') as Map)['domains'] as List)
          .cast<String>();
  Future<void> addDomain(String d) =>
      _req('POST', '/api/hostlist/add', body: {'domain': d});
  Future<void> removeDomain(String d) =>
      _req('POST', '/api/hostlist/remove', body: {'domain': d});
  Future<Map<String, dynamic>> searchService(String q) async =>
      (await _req('POST', '/api/services/search',
              body: {'query': q}, timeout: const Duration(seconds: 150)) as Map)
          .cast<String, dynamic>();
  Future<void> addService(String q, List<String> domains) =>
      _req('POST', '/api/services/add', body: {'query': q, 'domains': domains});
  Future<List<Map<String, dynamic>>> pending() async =>
      ((await _req('GET', '/api/changes') as Map)['pending'] as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
  Future<void> confirmChanges() => _req('POST', '/api/changes/confirm');
  Future<void> revertChanges() => _req('POST', '/api/changes/revert');
  Future<Map<String, dynamic>> presets() async =>
      (await _req('GET', '/api/presets') as Map).cast<String, dynamic>();
  Future<void> togglePreset(String name, bool on) =>
      _req('POST', '/api/presets/toggle', body: {'name': name, 'enabled': on});
  Future<dynamic> updatePopular() =>
      _req('POST', '/api/popular/update', timeout: const Duration(seconds: 180));
  Future<dynamic> applyAiBypass() =>
      _req('POST', '/api/aibypass/apply', timeout: const Duration(seconds: 60));

  /// Runs blockcheck; [onProgress] gets each line. Returns the final result.
  Future<Map<String, dynamic>> blockcheck(
      void Function(String line) onProgress, bool Function() cancelled) async {
    final ws = await WebSocket.connect(
        'ws://127.0.0.1:$port/ws/blockcheck?token=$token',
        headers: {'X-Zapret-Token': token});
    final done = Completer<Map<String, dynamic>>();
    final timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (cancelled() && !done.isCompleted) {
        ws.close();
        done.completeError(const _Cancelled());
      }
    });
    ws.listen((msg) {
      final m = (jsonDecode(msg as String) as Map).cast<String, dynamic>();
      if (m['type'] == 'progress') {
        onProgress('${m['message']}');
      } else if (m['type'] == 'done' && !done.isCompleted) {
        done.complete((m['result'] as Map).cast<String, dynamic>());
      } else if (m['type'] == 'error' && !done.isCompleted) {
        done.completeError(Exception('${m['message']}'));
      }
    }, onDone: () {
      if (!done.isCompleted) done.completeError(Exception('connection closed'));
    }, onError: (e) {
      if (!done.isCompleted) done.completeError(e);
    });
    try {
      return await done.future;
    } finally {
      timer.cancel();
      await ws.close();
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// Bypass mode chosen on the main tab.
enum BypassMode { vpn, zapret, both }

class ZapretScreen extends StatefulWidget {
  static RouteSettings routSettings() =>
      const RouteSettings(name: "ZapretScreen");

  const ZapretScreen({super.key});

  @override
  State<ZapretScreen> createState() => _ZapretScreenState();
}

class _ZapretScreenState extends State<ZapretScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  int _lastTab = 0;
  bool _guarding = false;

  ZapretApi? _api;
  bool _loading = true;
  bool _serviceBusy = false;
  String? _error;

  // main tab
  bool _winwsRunning = false;
  List<String> _strategies = [];
  String? _strategy;
  bool _checking = false;
  bool _cancelCheck = false;
  final List<String> _checkLog = [];

  // sites tab
  List<String> _domains = [];
  final TextEditingController _domainCtl = TextEditingController();
  final TextEditingController _filterCtl = TextEditingController();

  // services tab
  final TextEditingController _serviceCtl = TextEditingController();
  bool _searching = false;
  Map<String, dynamic>? _found;
  final Set<String> _picked = {};
  Map<String, dynamic> _presets = {};

  // changes
  List<Map<String, dynamic>> _pending = [];

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTab);
    _connect();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _domainCtl.dispose();
    _filterCtl.dispose();
    _serviceCtl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final info = await FlutterVpnService.zapretInfo();
    if (!mounted) return;
    if (info == null || !info.running || info.token.isEmpty) {
      setState(() {
        _api = null;
        _loading = false;
      });
      return;
    }
    _api = ZapretApi(info.port, info.token);
    // The backend needs a moment after start.
    for (var i = 0; i < 20; i++) {
      try {
        await _refreshAll();
        break;
      } catch (e) {
        if (i == 19) _error = e.toString();
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshAll() async {
    final api = _api!;
    final st = await api.status();
    final domains = await api.hostlist();
    final presets = await api.presets();
    final pending = await api.pending();
    if (!mounted) return;
    setState(() {
      _winwsRunning = st['running'] == true;
      _strategies = ((st['strategies'] as List?) ?? []).cast<String>();
      final saved = SettingManager.getConfig().zapretStrategy;
      _strategy ??= _strategies.contains(saved)
          ? saved
          : (_strategies.isNotEmpty ? _strategies.first : null);
      _domains = domains;
      _presets = presets;
      _pending = pending;
    });
  }

  Future<void> _refreshPending() async {
    if (_api == null) return;
    try {
      final p = await _api!.pending();
      if (mounted) setState(() => _pending = p);
    } catch (_) {}
  }

  Future<void> _setEngine(bool on) async {
    setState(() => _serviceBusy = true);
    final err =
        await FlutterVpnService.zapretSet(PathUtils.serviceExePath(), on);
    if (!mounted) return;
    setState(() => _serviceBusy = false);
    if (err != null) {
      _snack(err.message);
      return;
    }
    await _connect();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  Future<T?> _guard<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      if (mounted) _snack(e.toString());
      return null;
    }
  }

  // --- unsaved changes guard (in-app dialog, not a system one) -------------

  void _onTab() {
    if (_tabs.indexIsChanging || _guarding) return;
    final from = _lastTab;
    _lastTab = _tabs.index;
    if ((from == 1 || from == 2) && _pending.isNotEmpty) {
      _askSaveChanges(from);
    }
    if (_tabs.index == 3) _refreshPending();
  }

  Future<void> _askSaveChanges(int returnTo) async {
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(_tr("Сохранить изменения?", "Save changes?")),
        content: Text(_tr(
            "Есть несохранённые изменения списка обхода: ${_pending.length}.",
            "There are unsaved bypass list changes: ${_pending.length}.")),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, "stay"),
              child: Text(_tr("Остаться", "Stay"))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, "revert"),
              child: Text(_tr("Отменить изменения", "Revert"))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, "save"),
              child: Text(_tr("Сохранить", "Save"))),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == "stay") {
      _guarding = true;
      _tabs.animateTo(returnTo);
      _lastTab = returnTo;
      _guarding = false;
      return;
    }
    await _guard(() async {
      if (choice == "save") {
        await _api!.confirmChanges();
      } else {
        await _api!.revertChanges();
      }
      await _refreshAll();
    });
  }

  // --- main tab -------------------------------------------------------------

  Future<void> _startStrategy() async {
    final s = _strategy;
    if (s == null) return;
    final r = await _guard(() => _api!.start(s));
    if (r == null) return;
    SettingManager.getConfig().zapretStrategy = s;
    SettingManager.setDirty(true);
    if (r['ok'] != true) _snack('${r['message']}');
    await _guard(_refreshAll);
  }

  Future<void> _stopStrategy() async {
    await _guard(() => _api!.stop());
    await _guard(_refreshAll);
  }

  Future<void> _autoSelectStrategy() async {
    setState(() {
      _checking = true;
      _cancelCheck = false;
      _checkLog.clear();
    });
    try {
      final r = await _api!.blockcheck((line) {
        if (mounted) setState(() => _checkLog.add(line));
      }, () => _cancelCheck);
      final best = r['best'];
      final name = best is Map ? '${best['strategy']}' : null;
      if (name != null && _strategies.contains(name)) {
        setState(() => _strategy = name);
        _snack(_tr("Лучшая стратегия: $name", "Best strategy: $name"));
        await _startStrategy();
      } else {
        _snack(_tr("Рабочая стратегия не найдена", "No working strategy found"));
      }
    } on _Cancelled {
      _snack(_tr("Автоподбор остановлен", "Auto-select stopped"));
    } catch (e) {
      if (mounted) _snack(e.toString());
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Widget _mainTab() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: ListTile(
          leading: Icon(_winwsRunning ? Icons.shield : Icons.shield_outlined,
              color: _winwsRunning ? Colors.green : null),
          title: Text(_winwsRunning
              ? _tr("Обход DPI работает", "DPI bypass is running")
              : _tr("Обход DPI остановлен", "DPI bypass is stopped")),
          subtitle: Text(_strategy ?? _tr("Стратегия не выбрана", "No strategy")),
        ),
      ),
      const SizedBox(height: 12),
      Text(_tr("Стратегия", "Strategy"),
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      DropdownButtonFormField<String>(
        initialValue: _strategy,
        isExpanded: true,
        items: _strategies
            .map((s) => DropdownMenuItem(value: s, child: Text(s)))
            .toList(),
        onChanged: _checking ? null : (v) => setState(() => _strategy = v),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
            onPressed: _checking ? null : _startStrategy,
            icon: const Icon(Icons.play_arrow),
            label: Text(_winwsRunning
                ? _tr("Перезапустить", "Restart")
                : _tr("Запустить", "Start"))),
        OutlinedButton.icon(
            onPressed: _checking || !_winwsRunning ? null : _stopStrategy,
            icon: const Icon(Icons.stop),
            label: Text(_tr("Остановить", "Stop"))),
        OutlinedButton.icon(
            onPressed: _checking ? null : _autoSelectStrategy,
            icon: const Icon(Icons.auto_fix_high),
            label: Text(_tr("Автоподбор стратегии", "Auto-select strategy"))),
      ]),
      if (_checking && _checkLog.isNotEmpty) ...[
        const SizedBox(height: 10),
        const LinearProgressIndicator(),
        const SizedBox(height: 6),
        SizedBox(
          height: 160,
          child: ListView(
            reverse: true,
            children: _checkLog.reversed
                .map((l) => Text(l, style: const TextStyle(fontSize: 12)))
                .toList(),
          ),
        ),
        TextButton(
            onPressed: () => setState(() => _cancelCheck = true),
            child: Text(_tr("Остановить подбор", "Stop auto-select"))),
      ],
      const Divider(height: 32),
      Text(
          _tr("Режим обхода (VPN / Zapret / VPN + Zapret) выбирается на главном экране.",
              "The bypass mode (VPN / Zapret / VPN + Zapret) is chosen on the home screen."),
          style: Theme.of(context).textTheme.bodySmall),
    ]);
  }

  // --- sites tab --------------------------------------------------------------

  Widget _sitesTab() {
    final filter = _filterCtl.text.trim().toLowerCase();
    final shown = filter.isEmpty
        ? _domains
        : _domains.where((d) => d.contains(filter)).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _domainCtl,
              decoration: InputDecoration(
                  hintText: _tr("Сайт, например example.com", "Site, e.g. example.com"),
                  border: const OutlineInputBorder()),
              onSubmitted: (_) => _addDomain(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: _addDomain, child: Text(_tr("Добавить", "Add"))),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: TextField(
          controller: _filterCtl,
          decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: _tr("Поиск в списке (${_domains.length})",
                  "Search the list (${_domains.length})")),
          onChanged: (_) => setState(() {}),
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: shown.length,
          itemBuilder: (ctx, i) => ListTile(
            dense: true,
            title: Text(shown[i]),
            trailing: IconButton(
              icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
              onPressed: () async {
                await _guard(() => _api!.removeDomain(shown[i]));
                await _guard(_refreshAll);
              },
            ),
          ),
        ),
      ),
    ]);
  }

  Future<void> _addDomain() async {
    final d = _domainCtl.text.trim().toLowerCase();
    if (d.isEmpty) return;
    await _guard(() => _api!.addDomain(d));
    _domainCtl.clear();
    await _guard(_refreshAll);
  }

  // --- services tab -------------------------------------------------------------

  Future<void> _searchService() async {
    final q = _serviceCtl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _found = null;
      _picked.clear();
    });
    final r = await _guard(() => _api!.searchService(q));
    if (!mounted) return;
    setState(() {
      _searching = false;
      _found = r;
      if (r != null) {
        _picked.addAll(((r['preset_domains'] as List?) ?? []).cast<String>());
        for (final root in (r['roots'] as List? ?? [])) {
          _picked.addAll(((root as Map)['domains'] as List).cast<String>());
        }
      }
    });
  }

  Widget _servicesTab() {
    final found = _found;
    final rows = <Widget>[];
    if (found != null) {
      final preset = ((found['preset_domains'] as List?) ?? []).cast<String>();
      if (preset.isNotEmpty) {
        rows.add(_domainGroup(_tr("Готовый набор", "Curated set"), preset));
      }
      for (final root in (found['roots'] as List? ?? [])) {
        final m = (root as Map).cast<String, dynamic>();
        rows.add(_domainGroup(
            "${m['root']} (${m['count']})", (m['domains'] as List).cast<String>()));
      }
      final failed = ((found['failed'] as List?) ?? []).cast<String>();
      if (failed.isNotEmpty) {
        rows.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
              _tr("Не удалось проверить: ${failed.join(', ')}",
                  "Could not check: ${failed.join(', ')}"),
              style: const TextStyle(color: Colors.orange)),
        ));
      }
      if (rows.isEmpty) {
        rows.add(Text(_tr("Ничего не найдено", "Nothing found")));
      } else {
        rows.add(FilledButton.icon(
          onPressed: _picked.isEmpty
              ? null
              : () async {
                  await _guard(() => _api!
                      .addService(found['query'] ?? '', _picked.toList()));
                  setState(() => _found = null);
                  await _guard(_refreshAll);
                },
          icon: const Icon(Icons.add),
          label: Text(_tr("Добавить выбранные (${_picked.length})",
              "Add selected (${_picked.length})")),
        ));
      }
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(
          _tr("Введите название сервиса — адреса подтянутся сами.",
              "Type a service name; its addresses are found for you."),
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 6),
      // Search field with an animation on top while the lookup runs.
      Stack(children: [
        TextField(
          controller: _serviceCtl,
          enabled: !_searching,
          decoration: InputDecoration(
            hintText: _tr("Например: discord, youtube, telegram",
                "For example: discord, youtube, telegram"),
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
                icon: const Icon(Icons.search), onPressed: _searchService),
          ),
          onSubmitted: (_) => _searchService(),
        ),
        if (_searching)
          const Positioned(
              left: 0, right: 0, bottom: 0, child: LinearProgressIndicator()),
      ]),
      if (_searching)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_tr("Ищу адреса сервиса, это может занять до минуты…",
              "Looking up the service, this can take up to a minute…")),
        ),
      const SizedBox(height: 10),
      ...rows,
      const Divider(height: 32),
      Text(_tr("Наборы сервисов", "Service sets"),
          style: Theme.of(context).textTheme.titleMedium),
      ..._presets.entries.map((e) {
        final p = (e.value as Map).cast<String, dynamic>();
        return SwitchListTile(
          title: Text('${p['title']}'),
          subtitle: Text("${p['kind']} · ${p['count']}"),
          value: p['enabled'] == true,
          onChanged: (v) async {
            await _guard(() => _api!.togglePreset(e.key, v));
            await _guard(_refreshAll);
          },
        );
      }),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.trending_up),
          label: Text(_tr("Обновить популярные", "Update popular")),
          onPressed: () async {
            await _guard(() => _api!.updatePopular());
            await _guard(_refreshAll);
          },
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.smart_toy_outlined),
          label: Text(_tr("Нейросети (ИИ-сервисы)", "AI services")),
          onPressed: () async {
            await _guard(() => _api!.applyAiBypass());
            await _guard(_refreshAll);
          },
        ),
      ]),
    ]);
  }

  Widget _domainGroup(String title, List<String> domains) {
    return ExpansionTile(
      title: Text(title),
      initiallyExpanded: domains.length <= 8,
      children: domains
          .map((d) => CheckboxListTile(
                dense: true,
                value: _picked.contains(d),
                title: Text(d),
                onChanged: (v) => setState(
                    () => v == true ? _picked.add(d) : _picked.remove(d)),
              ))
          .toList(),
    );
  }

  // --- changes tab ------------------------------------------------------------

  Widget _changesTab() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (_pending.isEmpty)
        Text(_tr("Несохранённых изменений нет", "No unsaved changes"))
      else ...[
        ..._pending.map((e) => ListTile(
              leading: const Icon(Icons.edit_note),
              title: Text('${e['label']}'),
              subtitle: Text('${e['time']}'),
            )),
        const SizedBox(height: 10),
        Row(children: [
          FilledButton(
            onPressed: () async {
              await _guard(() => _api!.confirmChanges());
              await _guard(_refreshAll);
            },
            child: Text(_tr("Сохранить всё", "Save all")),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () async {
              await _guard(() => _api!.revertChanges());
              await _guard(_refreshAll);
            },
            child: Text(_tr("Отменить всё", "Revert all")),
          ),
        ]),
      ],
    ]);
  }

  // --- layout -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final on = _api != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text("Zapret"),
        actions: [
          if (_serviceBusy)
            const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)))
          else
            Switch.adaptive(value: on, onChanged: _setEngine),
          IconButton(
              onPressed: _loading ? null : _connect,
              icon: const Icon(Icons.refresh)),
        ],
        bottom: on
            ? TabBar(controller: _tabs, isScrollable: true, tabs: [
                Tab(text: _tr("Главное", "Main")),
                Tab(text: _tr("Сайты", "Sites")),
                Tab(text: _tr("Сервисы", "Services")),
                Tab(
                    text: _pending.isEmpty
                        ? _tr("Изменения", "Changes")
                        : _tr("Изменения (${_pending.length})",
                            "Changes (${_pending.length})")),
              ])
            : null,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : !on
                  ? _offView()
                  : _error != null
                      ? Center(child: Text(_error!))
                      : TabBarView(controller: _tabs, children: [
                          _mainTab(),
                          _sitesTab(),
                          _servicesTab(),
                          _changesTab(),
                        ]),
        ),
      ),
    );
  }

  Widget _offView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.shield_outlined, size: 64),
          const SizedBox(height: 12),
          Text(
            _tr("Zapret выключен", "Zapret is off"),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            _tr(
                "Обход блокировок DPI без VPN. Включение запускает модуль zapret в службе Karing+.",
                "DPI bypass without VPN. Turning it on starts the zapret module in the Karing+ service."),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
              onPressed: _serviceBusy ? null : () => _setEngine(true),
              icon: const Icon(Icons.power_settings_new),
              label: Text(_tr("Включить", "Turn on"))),
        ]),
      ),
    );
  }
}
