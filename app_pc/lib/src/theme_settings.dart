import 'dart:io';
import 'package:flutter/material.dart';

enum PcThemeMode {
  system('跟随系统', ThemeMode.system),
  light('浅色模式', ThemeMode.light),
  dark('深色模式', ThemeMode.dark);

  const PcThemeMode(this.label, this.mode);
  final String label;
  final ThemeMode mode;

  static PcThemeMode parse(String? value) {
    return PcThemeMode.values.firstWhere(
      (m) => m.name == value,
      orElse: () => PcThemeMode.system,
    );
  }
}

class PcThemeSettings extends ChangeNotifier {
  PcThemeSettings._();
  static final PcThemeSettings instance = PcThemeSettings._();

  PcThemeMode _mode = PcThemeMode.system;
  PcThemeMode get mode => _mode;
  ThemeMode get themeMode => _mode.mode;

  static File get _file {
    final base = Platform.environment['LOCALAPPDATA'] ?? Directory.current.path;
    return File(
      '$base${Platform.pathSeparator}DexLink${Platform.pathSeparator}theme.txt',
    );
  }

  void init() {
    try {
      if (_file.existsSync()) {
        final text = _file.readAsStringSync().trim();
        _mode = PcThemeMode.parse(text);
      }
    } catch (_) {}
  }

  Future<void> setMode(PcThemeMode newMode) async {
    if (_mode == newMode) return;
    _mode = newMode;
    notifyListeners();
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(newMode.name, flush: true);
    } catch (_) {}
  }
}
