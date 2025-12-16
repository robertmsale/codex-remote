import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../services/session_scrollback_service.dart';
import '../../services/theme_mode_service.dart';

class SettingsController extends SettingsControllerBase {
  final ThemeModeService _theme = Get.find<ThemeModeService>();
  final SessionScrollbackService _scrollback = Get.find<SessionScrollbackService>();

  @override
  Rx<ThemeMode> get themeMode => _theme.modeRx;

  @override
  Future<void> setThemeMode(ThemeMode mode) => _theme.setMode(mode);

  @override
  RxInt get sessionScrollbackLines => _scrollback.linesRx;

  @override
  Future<void> setSessionScrollbackLines(int lines) => _scrollback.setLines(lines);
}
