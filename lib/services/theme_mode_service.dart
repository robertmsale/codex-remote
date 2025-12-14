import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeModeService {
  static const _key = 'field_exec_theme_mode_v1';

  final modeRx = ThemeMode.system.obs;

  ThemeMode get mode => modeRx.value;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    modeRx.value = _parse(raw) ?? ThemeMode.system;
  }

  Future<void> setMode(ThemeMode mode) async {
    modeRx.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, _encode(mode));
  }

  static ThemeMode? _parse(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'system':
        return ThemeMode.system;
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
    }
    return null;
  }

  static String _encode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'system';
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
    }
  }
}
