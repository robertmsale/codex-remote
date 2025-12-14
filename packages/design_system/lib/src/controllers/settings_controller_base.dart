import 'package:flutter/material.dart';
import 'package:get/get.dart';

abstract class SettingsControllerBase extends GetxController {
  Rx<ThemeMode> get themeMode;
  Future<void> setThemeMode(ThemeMode mode);
}
