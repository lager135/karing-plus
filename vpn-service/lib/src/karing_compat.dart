import 'dart:convert';

/// Karing writes a few config fields that only its own sing-box fork understands. Standard sing-box
/// (our libbox and karingService) rejects them, so the config is rewritten before it reaches the core.
/// Same rules as normalizeKaring in karingService (compat.go).
String normalizeKaringConfig(String configJson) {
  final Object? root;
  try {
    root = jsonDecode(configJson);
  } catch (_) {
    return configJson;
  }
  if (root is! Map<String, dynamic>) return configJson;
  final dns = root['dns'];
  if (dns is Map<String, dynamic>) {
    final servers = dns['servers'];
    if (servers is List) {
      for (final s in servers) {
        if (s is! Map<String, dynamic>) continue;
        // Karing: "addresses": [a, b]. sing-box: one "address"; keep the first.
        final list = s.remove('addresses');
        if (list is List && !s.containsKey('address')) {
          final first = list.whereType<String>().where((a) => a.isNotEmpty);
          if (first.isNotEmpty) s['address'] = first.first;
        }
      }
    }
    _dropKey(dns['rules'], 'name');
  }
  final route = root['route'];
  if (route is Map<String, dynamic>) _dropKey(route['rules'], 'name');
  return jsonEncode(root);
}

void _dropKey(Object? list, String key) {
  if (list is! List) return;
  for (final item in list) {
    if (item is Map) item.remove(key);
  }
}

/// Removes the field named in a sing-box error like `dns.rules[0].foo: json: unknown field "foo"`.
/// Returns null when the error is of another kind or the field is not found.
String? dropUnknownField(String configJson, String error) {
  final m = RegExp(r'([A-Za-z0-9_.\[\]]+): json: unknown field "([^"]+)"')
      .firstMatch(error);
  if (m == null) return null;
  final field = m.group(2)!;
  final segs = m
      .group(1)!
      .replaceAll('[', '.')
      .replaceAll(']', '')
      .split('.')
      .where((s) => s.isNotEmpty)
      .toList();
  if (segs.isNotEmpty && segs.last == field) segs.removeLast();
  Object? node;
  try {
    node = jsonDecode(configJson);
  } catch (_) {
    return null;
  }
  final root = node;
  for (final s in segs) {
    if (node is Map) {
      node = node[s];
    } else if (node is List) {
      final i = int.tryParse(s);
      if (i == null || i < 0 || i >= node.length) return null;
      node = node[i];
    } else {
      return null;
    }
  }
  if (node is! Map || !node.containsKey(field)) return null;
  node.remove(field);
  return jsonEncode(root);
}
