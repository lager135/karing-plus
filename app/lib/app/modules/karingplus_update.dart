import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:karing/app/modules/setting_manager.dart';
import 'package:karing/app/utils/app_utils.dart';
import 'package:karing/app/utils/log.dart';
import 'package:karing/app/utils/url_launcher_utils.dart';

// Karing+: update check against the project's GitHub releases. When the user closes the prompt
// it stays quiet for 24 hours.
class KaringPlusUpdate {
  static const String repo = "lager135/karing-plus";
  static const String releasesUrl = "https://github.com/$repo/releases";
  static const Duration snooze = Duration(hours: 24);

  static bool _checking = false;

  static Future<void> check(BuildContext context) async {
    if (_checking) {
      return;
    }
    final setting = SettingManager.getConfig();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < setting.updateSnoozeUntil) {
      return;
    }
    _checking = true;
    try {
      final latest = await _latestRelease();
      if (latest == null || !context.mounted) {
        return;
      }
      if (_compare(latest.version, AppUtils.getDisplayVersion()) <= 0) {
        return;
      }
      final ru = setting.languageTag.startsWith("ru");
      final open = await showDialog<bool>(
        context: context,
        routeSettings: const RouteSettings(name: "karingPlusUpdate"),
        builder: (context) => AlertDialog(
          title: Text(ru ? "Доступно обновление" : "Update available"),
          content: Text(ru
              ? "Karing+ ${latest.version} (у вас ${AppUtils.getDisplayVersion()})."
              : "Karing+ ${latest.version} (you have ${AppUtils.getDisplayVersion()})."),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(ru ? "Закрыть" : "Close"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(ru ? "Открыть" : "Open"),
            ),
          ],
        ),
      );
      // Closed, dismissed or opened: do not ask again for 24 hours.
      setting.updateSnoozeUntil =
          DateTime.now().add(snooze).millisecondsSinceEpoch;
      SettingManager.saveConfig();
      if (open == true) {
        await UrlLauncherUtils.loadUrl(latest.url);
      }
    } catch (e) {
      Log.w("KaringPlusUpdate.check: $e");
    } finally {
      _checking = false;
    }
  }

  static Future<({String version, String url})?> _latestRelease() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client
          .getUrl(Uri.parse("https://api.github.com/repos/$repo/releases?per_page=10"));
      req.headers.set(HttpHeaders.acceptHeader, "application/vnd.github+json");
      req.headers.set(HttpHeaders.userAgentHeader, "Karing+");
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      final list = jsonDecode(body) as List<dynamic>;
      // Pre-releases count too: Karing+ ships betas (X.Y.Z_b).
      for (final r in list) {
        if (r is! Map || r["draft"] == true) {
          continue;
        }
        final tag = (r["tag_name"] ?? "").toString();
        if (_parse(tag) == null) {
          continue;
        }
        final version = tag.startsWith("v") ? tag.substring(1) : tag;
        return (version: version, url: (r["html_url"] ?? releasesUrl).toString());
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  // "v0.1.0_b" -> [0, 1, 0]
  static List<int>? _parse(String v) {
    final m = RegExp(r"^v?(\d+)\.(\d+)\.(\d+)").firstMatch(v);
    if (m == null) {
      return null;
    }
    return [int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)];
  }

  static int _compare(String a, String b) {
    final x = _parse(a), y = _parse(b);
    if (x == null || y == null) {
      return 0;
    }
    for (var i = 0; i < 3; i++) {
      if (x[i] != y[i]) {
        return x[i].compareTo(y[i]);
      }
    }
    return 0;
  }
}
