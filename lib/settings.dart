import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide preferences, persisted in shared_preferences.
/// ponytail: typed accessors over string keys; a schema class per section
/// isn't worth it for a dozen values.
class AppSettings extends ChangeNotifier {
  late SharedPreferences _p;

  Future<void> load() async => _p = await SharedPreferences.getInstance();

  /// Sign-ins to model sites: kept on this device, never in a backup file.
  static const secretKeys = {'models.creality.token', 'models.creality.uid', 'models.thingiverse'};

  /// Everything except [secretKeys], for a backup file.
  Map<String, Object?> exportAll() => {
        for (final k in _p.getKeys())
          if (!secretKeys.contains(k)) k: _p.get(k),
      };

  /// Restores a backup made by [exportAll]; unknown value types are skipped.
  Future<void> importAll(Map<String, dynamic> m) async {
    for (final e in m.entries) {
      final v = e.value;
      if (v is bool) await _p.setBool(e.key, v);
      if (v is int) await _p.setInt(e.key, v);
      if (v is double) await _p.setDouble(e.key, v);
      if (v is String) await _p.setString(e.key, v);
      if (v is List) await _p.setStringList(e.key, [for (final x in v) '$x']);
    }
    notifyListeners();
  }

  /// Per-printer colour (ARGB) to tell printers apart.
  int? printerColor(String key) => _p.getInt('printerColor.$key');
  void setPrinterColor(String key, int c) => _write(() => _p.setInt('printerColor.$key', c));

  static const _presetDefaults = {
    'nozzle': [0, 190, 210, 230, 250, 270],
    'bed': [0, 55, 60, 70, 80, 100],
    'chamber': [0, 35, 45, 55, 60],
  };

  /// 'dark', 'light' or 'system'.
  String get theme => _p.getString('theme') ?? 'dark';
  set theme(String v) => _write(() => _p.setString('theme', v));

  String get accent => _p.getString('accent') ?? 'Mint';
  set accent(String v) => _write(() => _p.setString('accent', v));

  List<int> presets(String heater) {
    final s = _p.getStringList('presets.$heater');
    if (s == null) return _presetDefaults[heater] ?? const [0];
    return [for (final v in s) ?int.tryParse(v)];
  }

  void setPresets(String heater, List<int> values) => _write(() =>
      _p.setStringList('presets.$heater', [for (final v in values) '$v']));

  double number(String key, double fallback) => _p.getDouble(key) ?? fallback;
  void setNumber(String key, double v) => _write(() => _p.setDouble(key, v));

  bool flag(String key, [bool fallback = true]) => _p.getBool(key) ?? fallback;
  void setFlag(String key, bool v) => _write(() => _p.setBool(key, v));

  String text(String key, [String fallback = '']) =>
      _p.getString(key) ?? fallback;
  void setText(String key, String v) => _write(() => _p.setString(key, v));

  List<String> strings(String key) => _p.getStringList(key) ?? const [];
  void setStrings(String key, List<String> v) =>
      _write(() => _p.setStringList(key, v));

  Set<String> favourites(String scope) => strings('fav.$scope').toSet();
  bool isFavourite(String scope, String name) =>
      favourites(scope).contains(name);
  void toggleFavourite(String scope, String name) {
    final f = favourites(scope);
    if (!f.remove(name)) f.add(name);
    setStrings('fav.$scope', f.toList());
  }

  List<Map<String, dynamic>> jsonList(String key) => [
        for (final e in jsonDecode(_p.getString(key) ?? '[]') as List)
          Map<String, dynamic>.from(e as Map),
      ];
  void setJsonList(String key, List<Map<String, dynamic>> v) =>
      _write(() => _p.setString(key, jsonEncode(v)));

  void _write(Future<bool> Function() write) {
    write();
    notifyListeners();
  }
}

final settings = AppSettings();
