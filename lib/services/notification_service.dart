import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin;
  Future<void>? _initFuture;

  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const initializationSettings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
    );

    try {
      await _plugin.initialize(
        initializationSettings,
        onDidReceiveNotificationResponse: (response) {
          // Future: deep-link into the specific project/tab using response.payload.
          if (kDebugMode) {
            debugPrint('Notification tapped: ${response.payload}');
          }
        },
      );
    } on MissingPluginException catch (_) {
      // Common in widget tests; notifications are best-effort.
      return;
    }

    // Request permissions (iOS/macOS). Best-effort; users may deny.
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {}

    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {}
  }

  Future<void> notifyTurnFinished({
    required String projectPath,
    required bool success,
    required String tabId,
    String? threadId,
  }) async {
    await init();

    final project = _basename(projectPath);
    final shortThread =
        (threadId != null && threadId.length >= 8) ? threadId.substring(0, 8) : null;

    final title = success ? 'Codex turn completed' : 'Codex turn failed';
    final body = [
      if (project.isNotEmpty) project,
      if (shortThread != null) 'thread $shortThread',
    ].join(' • ');

    const details = NotificationDetails(
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        presentBadge: false,
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        presentBadge: false,
      ),
    );

    final id = DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);
    await _plugin.show(
      id,
      title,
      body.isEmpty ? null : body,
      details,
      payload: '$projectPath|$tabId|${threadId ?? ''}',
    );
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/').where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? '' : parts.last;
  }
}
