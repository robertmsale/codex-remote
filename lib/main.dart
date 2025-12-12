import 'package:flutter/material.dart';

import 'app/codex_remote_app.dart';
import 'services/background_work_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackgroundWorkService().init();
  runApp(const CodexRemoteApp());
}
