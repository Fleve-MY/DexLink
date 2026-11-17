import 'dart:io';
import 'package:flutter/material.dart';

enum AppThemeMode {
  system('跟随系统', ThemeMode.system),
  light('浅色模式', ThemeMode.light),
  dark('深色模式', ThemeMode.dark);

  const AppThemeMode(this.label, this.mode);
  final String label;
  final ThemeMode mode;

  static AppThemeMode parse(String? value) {
    return AppThemeMode.values.firstWhere(
      (m) => m.name == value,
      orElse: () => AppThemeMode.system,
    );
  }
}

class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  AppThemeMode _currentMode = AppThemeMode.system;
  AppThemeMode get currentMode => _currentMode;
  ThemeMode get themeMode => _currentMode.mode;

  static File? _getFile() {
    try {
      final temp = Directory.systemTemp;
      // In Android, temp is typically /data/user/0/io.dexlink/cache.
      // Its parent is the app private dir /data/user/0/io.dexlink.
      final parent = temp.parent;
      final fileDir = Directory('${parent.path}/files');
      if (!fileDir.existsSync()) {
        fileDir.createSync(recursive: true);
      }
      return File('${fileDir.path}/dexlink_theme.txt');
    } catch (_) {
      return null;
    }
  }

  Future<void> init() async {
    try {
      final file = _getFile();
      if (file != null && await file.exists()) {
        final content = (await file.readAsString()).trim();
        _currentMode = AppThemeMode.parse(content);
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> setMode(AppThemeMode mode) async {
    if (_currentMode == mode) return;
    _currentMode = mode;
    notifyListeners();
    try {
      final file = _getFile();
      if (file != null) {
        await file.writeAsString(mode.name, flush: true);
      }
    } catch (_) {}
  }
}
