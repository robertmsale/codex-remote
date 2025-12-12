import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';

import '../background/codex_remote_workmanager.dart';

class BackgroundWorkService {
  Future<void> init() async {
    if (!Platform.isIOS) return;

    try {
      await Workmanager().initialize(codexRemoteCallbackDispatcher);
    } on MissingPluginException {
      return;
    } catch (_) {
      // Best-effort.
      return;
    }

    try {
      await Workmanager().registerPeriodicTask(
        codexRemoteBackgroundRefreshTaskId,
        codexRemoteBackgroundRefreshTaskId,
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      );
      if (kDebugMode) {
        // Useful when testing on-device.
        // ignore: avoid_print
        print(await Workmanager().printScheduledTasks());
      }
    } catch (_) {
      // Best-effort: task may already be registered or unsupported.
    }
  }
}

