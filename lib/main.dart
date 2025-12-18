import 'package:rinf/rinf.dart';
import 'src/bindings/bindings.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'dart:io';
import 'dart:convert';

import 'app/field_exec_app.dart';
import 'rinf/rust_hosts.dart';
import 'services/background_work_service.dart';
import 'services/session_scrollback_service.dart';
import 'services/theme_mode_service.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:design_system/design_system.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  ProjectArgs? startupProject;
  if (Platform.isMacOS || Platform.isLinux) {
    try {
      final window = await WindowController.fromCurrentEngine();
      startupProject = _parseStartupProjectArgs(window.arguments);
    } catch (_) {
      startupProject = null;
    }
  }

  final needsRust = Platform.isIOS || Platform.isAndroid;
  if (needsRust) {
    await initializeRust(assignRustSignal);
    await startRustHosts();
  }
  final theme = Get.put<ThemeModeService>(ThemeModeService(), permanent: true);
  await theme.init();
  final scrollback = Get.put<SessionScrollbackService>(
    SessionScrollbackService(),
    permanent: true,
  );
  await scrollback.init();
  await BackgroundWorkService().init();
  runApp(FieldExecApp(startupProjectArgs: startupProject));
}

ProjectArgs? _parseStartupProjectArgs(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final type = (decoded['type'] as String?)?.trim();
  if (type != 'open_project') return null;
  final projectJson = decoded['project'];
  final targetJson = decoded['target'];
  if (projectJson is! Map) return null;
  if (targetJson is! Map) return null;

  final project = Project.fromJson(Map<String, Object?>.from(projectJson));
  final local = (targetJson['local'] as bool?) ?? false;
  if (local) {
    return ProjectArgs(target: const TargetArgs.local(), project: project);
  }

  final profileJson = targetJson['profile'];
  if (profileJson is! Map) return null;
  final profile = ConnectionProfile.fromJson(
    Map<String, Object?>.from(profileJson),
  );
  return ProjectArgs(target: TargetArgs.remote(profile), project: project);
}
