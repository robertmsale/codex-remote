import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'app/codex_remote_app.dart';
import 'services/background_work_service.dart';
import 'services/theme_mode_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final theme = Get.put<ThemeModeService>(ThemeModeService(), permanent: true);
  await theme.init();
  await BackgroundWorkService().init();
  runApp(const CodexRemoteApp());
}
