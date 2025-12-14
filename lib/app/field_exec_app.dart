import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:design_system/design_system.dart';

import 'bindings/initial_binding.dart';
import 'routes/app_pages.dart';
import '../services/theme_mode_service.dart';

class FieldExecApp extends StatelessWidget {
  const FieldExecApp({super.key});

  ThemeData _lightTheme() {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
    );
  }

  ThemeData _darkTheme() {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: Brightness.dark,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = Get.isRegistered<ThemeModeService>()
        ? Get.find<ThemeModeService>()
        : null;

    if (service == null) {
      return GetMaterialApp(
        title: 'FieldExec',
        debugShowCheckedModeBanner: false,
        theme: _lightTheme(),
        darkTheme: _darkTheme(),
        themeMode: ThemeMode.system,
        initialBinding: InitialBinding(),
        initialRoute: DesignRoutes.connect,
        getPages: AppPages.pages,
      );
    }

    return Obx(
      () => GetMaterialApp(
        title: 'FieldExec',
        debugShowCheckedModeBanner: false,
        theme: _lightTheme(),
        darkTheme: _darkTheme(),
        themeMode: service.modeRx.value,
        initialBinding: InitialBinding(),
        initialRoute: DesignRoutes.connect,
        getPages: AppPages.pages,
      ),
    );
  }
}
