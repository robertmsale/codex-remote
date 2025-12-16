import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import 'app_lifecycle_service.dart';
import 'ssh_service.dart';

class SshLifecycleService {
  Worker? _worker;
  Timer? _debounce;
  AppLifecycleState? _pendingState;
  Future<void> _queue = Future.value();

  AppLifecycleService get _lifecycle => Get.find<AppLifecycleService>();
  SshService get _ssh => Get.find<SshService>();

  bool get _enabled => Platform.isIOS || Platform.isAndroid;

  void start() {
    if (!_enabled) return;
    if (_worker != null) return;

    _worker = ever<AppLifecycleState?>(_lifecycle.stateRx, (state) {
      if (state == null) return;
      _pendingState = state;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 150), () {
        final s = _pendingState;
        _pendingState = null;
        if (s == null) return;
        _queue = _queue.then((_) async {
          final reason = 'lifecycle:${s.name}';
          await _ssh.resetAllConnections(reason: reason);
        });
      });
    });
  }

  void stop() {
    try {
      _debounce?.cancel();
    } catch (_) {}
    _debounce = null;
    _pendingState = null;
    _worker?.dispose();
    _worker = null;
  }
}

