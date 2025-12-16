import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import 'package:design_system/design_system.dart';

import 'app_lifecycle_service.dart';
import 'project_store.dart';
import 'secure_storage_service.dart';
import 'ssh_service.dart';

class SharedProjectsService {
  static const _dirRelPath = '.config/field_exec';
  static const _projectsFileName = 'projects.json';
  static const _eventsFileName = 'project_events.jsonl';

  static const _version = 1;
  static const _maxProjects = 25;

  ProjectStore get _prefs => Get.find<ProjectStore>();
  AppLifecycleService get _lifecycle => Get.find<AppLifecycleService>();
  SecureStorageService get _storage => Get.find<SecureStorageService>();
  SshService get _ssh => Get.find<SshService>();

  Future<List<Project>> loadProjects({required TargetArgs target}) async {
    final shared = await _readSharedProjects(target: target);
    if (shared != null) {
      final normalized = _normalize(shared);
      await _prefs.saveProjects(
        targetKey: target.targetKey,
        projects: normalized,
      );
      return normalized;
    }

    final fallback = await _prefs.loadProjects(targetKey: target.targetKey);
    if (fallback.isEmpty) return const [];

    // Bootstrap a new shared file from the local cache if possible.
    try {
      await saveProjects(target: target, projects: fallback);
    } catch (_) {}
    return fallback;
  }

  Future<void> saveProjects({
    required TargetArgs target,
    required List<Project> projects,
  }) async {
    final normalized = _normalize(projects);
    await _prefs.saveProjects(targetKey: target.targetKey, projects: normalized);
    await _writeSharedProjects(target: target, projects: normalized);
  }

  SharedProjectsWatchHandle watchProjects({
    required TargetArgs target,
    required void Function() onChanged,
  }) {
    if (target.local) {
      return _LocalSharedProjectsWatchHandle(
        baseDir: _localBaseDir(),
        onChanged: onChanged,
      )..start();
    }
    return _RemoteSharedProjectsWatchHandle(
      target: target,
      lifecycle: _lifecycle,
      storage: _storage,
      ssh: _ssh,
      onChanged: onChanged,
    )..start();
  }

  static List<Project> _normalize(List<Project> raw) {
    final seenPaths = <String>{};
    final out = <Project>[];
    for (final p in raw) {
      final id = p.id.trim();
      final path = p.path.trim();
      final name = p.name.trim();
      if (id.isEmpty || path.isEmpty || name.isEmpty) continue;
      final key = path.toLowerCase();
      if (seenPaths.contains(key)) continue;
      seenPaths.add(key);
      out.add(p);
      if (out.length >= _maxProjects) break;
    }
    return out;
  }

  static String _localHome() => (Platform.environment['HOME'] ?? '').trim();

  static Directory? _localBaseDir() {
    if (!Platform.isMacOS && !Platform.isLinux) return null;
    final home = _localHome();
    if (home.isEmpty) return null;
    return Directory('$home/$_dirRelPath');
  }

  static File? _localProjectsFile() {
    final base = _localBaseDir();
    if (base == null) return null;
    return File('${base.path}/$_projectsFileName');
  }

  static File? _localEventsFile() {
    final base = _localBaseDir();
    if (base == null) return null;
    return File('${base.path}/$_eventsFileName');
  }

  Future<List<Project>?> _readSharedProjects({required TargetArgs target}) async {
    try {
      if (target.local) {
        final file = _localProjectsFile();
        if (file == null || !await file.exists()) return null;
        final raw = (await file.readAsString()).trim();
        if (raw.isEmpty) return null;
        return _decodeProjectsJson(raw);
      }

      final profile = target.profile;
      if (profile == null) return null;
      final pem =
          (await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey))
              ?.trim() ??
          '';
      if (pem.isEmpty) return null;

      final script = [
        'BASE="\$HOME/$_dirRelPath"',
        'if [ -f "\$BASE/$_projectsFileName" ]; then cat "\$BASE/$_projectsFileName"; fi',
      ].join('\n');
      final res = await _ssh.runCommandWithResult(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: null,
        command: _wrapWithShell(profile.shell, script),
        timeout: const Duration(seconds: 10),
        retries: 0,
      );
      final raw = res.stdout.trim();
      if (raw.isEmpty) return null;
      return _decodeProjectsJson(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSharedProjects({
    required TargetArgs target,
    required List<Project> projects,
  }) async {
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final payload = <String, Object?>{
      'version': _version,
      'updated_at_ms_utc': nowMs,
      'projects': projects.map((p) => p.toJson()).toList(growable: false),
    };
    final json = jsonEncode(payload);

    if (target.local) {
      final base = _localBaseDir();
      final projectsFile = _localProjectsFile();
      final eventsFile = _localEventsFile();
      if (base == null || projectsFile == null || eventsFile == null) return;

      await base.create(recursive: true);
      try {
        await Process.run('chmod', ['700', base.path]);
      } catch (_) {}

      final tmp = File('${projectsFile.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(projectsFile.path);
      try {
        await Process.run('chmod', ['600', projectsFile.path]);
      } catch (_) {}

      final evt = jsonEncode(<String, Object?>{
        'type': 'projects.updated',
        'updated_at_ms_utc': nowMs,
      });
      await eventsFile.parent.create(recursive: true);
      await eventsFile.writeAsString('$evt\n', mode: FileMode.append, flush: true);
      try {
        await Process.run('chmod', ['600', eventsFile.path]);
      } catch (_) {}
      return;
    }

    final profile = target.profile;
    if (profile == null) return;
    final pem =
        (await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey))?.trim() ??
        '';
    if (pem.isEmpty) return;

    final b64 = base64.encode(utf8.encode(json));
    final eventLine = jsonEncode(<String, Object?>{
      'type': 'projects.updated',
      'updated_at_ms_utc': nowMs,
    });

    final script = [
      'BASE="\$HOME/$_dirRelPath"',
      'mkdir -p "\$BASE" >/dev/null 2>&1 || true',
      'chmod 700 "\$BASE" >/dev/null 2>&1 || true',
      'tmp="\$BASE/$_projectsFileName.tmp"',
      'b64=${_shQuote(b64)}',
      r'printf %s "$b64" | base64 -D 2>/dev/null > "$tmp" || printf %s "$b64" | base64 -d 2>/dev/null > "$tmp"',
      'mv "\$tmp" "\$BASE/$_projectsFileName"',
      'chmod 600 "\$BASE/$_projectsFileName" >/dev/null 2>&1 || true',
      'touch "\$BASE/$_eventsFileName" >/dev/null 2>&1 || true',
      'chmod 600 "\$BASE/$_eventsFileName" >/dev/null 2>&1 || true',
      'printf %s\\\\n ${_shQuote(eventLine)} >> "\$BASE/$_eventsFileName"',
    ].join('\n');

    await _ssh.runCommandWithResult(
      host: profile.host,
      port: profile.port,
      username: profile.username,
      privateKeyPem: pem,
      password: null,
      command: _wrapWithShell(profile.shell, script),
      timeout: const Duration(seconds: 15),
      retries: 1,
    );
  }

  static List<Project>? _decodeProjectsJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final list = decoded['projects'];
      if (list is! List) return null;
      return list
          .whereType<Map>()
          .map((m) => Project.fromJson(m.cast<String, Object?>()))
          .where((p) => p.id.isNotEmpty && p.path.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  static String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static String _wrapWithShell(PosixShell shell, String body) {
    switch (shell) {
      case PosixShell.sh:
        return 'sh -c ${_shQuote(body)}';
      case PosixShell.bash:
        return 'bash --noprofile --norc -c ${_shQuote(body)}';
      case PosixShell.zsh:
        return 'zsh -f -c ${_shQuote(body)}';
      case PosixShell.fizsh:
        return 'fizsh -f -c ${_shQuote(body)}';
    }
  }
}

abstract class SharedProjectsWatchHandle {
  void start();
  void cancel();
}

class _LocalSharedProjectsWatchHandle implements SharedProjectsWatchHandle {
  final Directory? baseDir;
  final void Function() onChanged;
  StreamSubscription<FileSystemEvent>? _sub;

  _LocalSharedProjectsWatchHandle({
    required this.baseDir,
    required this.onChanged,
  });

  @override
  void start() {
    final dir = baseDir;
    if (dir == null) return;
    try {
      dir.createSync(recursive: true);
    } catch (_) {}
    _sub?.cancel();
    _sub = dir.watch(recursive: false).listen((evt) {
      final p = evt.path;
      if (!p.endsWith('projects.json') && !p.endsWith('project_events.jsonl')) {
        return;
      }
      onChanged();
    });
  }

  @override
  void cancel() {
    try {
      _sub?.cancel();
    } catch (_) {}
    _sub = null;
  }
}

class _RemoteSharedProjectsWatchHandle implements SharedProjectsWatchHandle {
  final TargetArgs target;
  final AppLifecycleService lifecycle;
  final SecureStorageService storage;
  final SshService ssh;
  final void Function() onChanged;

  Worker? _lifecycleWorker;
  SshCommandProcess? _proc;
  StreamSubscription<String>? _outSub;
  StreamSubscription<String>? _errSub;
  Timer? _restartDebounce;
  Object? _token;

  _RemoteSharedProjectsWatchHandle({
    required this.target,
    required this.lifecycle,
    required this.storage,
    required this.ssh,
    required this.onChanged,
  });

  bool _enabled() => Platform.isIOS || Platform.isAndroid || Platform.isMacOS || Platform.isLinux;

  @override
  void start() {
    if (!_enabled()) return;
    _lifecycleWorker ??= ever<AppLifecycleState?>(lifecycle.stateRx, (state) {
      if (state == null) return;
      if (state == AppLifecycleState.resumed) {
        _scheduleRestart();
      } else if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.inactive ||
          state == AppLifecycleState.detached) {
        _stop();
      }
    });
    if (!lifecycle.isForeground) return;
    _scheduleRestart();
  }

  void _scheduleRestart() {
    _restartDebounce?.cancel();
    _restartDebounce = Timer(const Duration(milliseconds: 250), () {
      _restartDebounce = null;
      if (!lifecycle.isForeground) return;
      _startTail();
    });
  }

  Future<void> _startTail() async {
    if (!lifecycle.isForeground) return;
    final profile = target.profile;
    if (profile == null) return;
    final pem =
        (await storage.read(key: SecureStorageService.sshPrivateKeyPemKey))?.trim() ??
        '';
    if (pem.isEmpty) return;

    _token ??= Object();
    final token = _token!;

    // Always tear down and restart to avoid half-dead pooled SSH streams.
    _stop();

    try {
      final ensure = [
        'BASE="\$HOME/.config/field_exec"',
        'mkdir -p "\$BASE" >/dev/null 2>&1 || true',
        'touch "\$BASE/projects.json" "\$BASE/project_events.jsonl" >/dev/null 2>&1 || true',
      ].join('\n');
      await ssh.runCommandWithResult(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: null,
        command: SharedProjectsService._wrapWithShell(profile.shell, ensure),
        timeout: const Duration(seconds: 8),
        retries: 0,
      );

      final tailBody = [
        'BASE="\$HOME/.config/field_exec"',
        'tail -n 0 -F "\$BASE/project_events.jsonl"',
      ].join('\n');

      final proc = await ssh.startCommand(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: null,
        command: SharedProjectsService._wrapWithShell(profile.shell, tailBody),
        connectTimeout: const Duration(seconds: 10),
        retries: 1,
      );

      if (_token != token) {
        proc.cancel();
        return;
      }

      _proc = proc;
      _outSub = proc.stdoutLines.listen((line) {
        if (line.trim().isEmpty) return;
        if (!line.contains('projects.updated')) return;
        onChanged();
      });
      _errSub = proc.stderrLines.listen((_) {});

      unawaited(
        proc.done.catchError((_) {}).whenComplete(() {
          if (_token != token) return;
          _stop();
          if (!lifecycle.isForeground) return;
          _scheduleRestart();
        }),
      );
    } catch (_) {
      if (_token != token) return;
      _stop();
      if (!lifecycle.isForeground) return;
      _scheduleRestart();
    }
  }

  void _stop() {
    try {
      _outSub?.cancel();
    } catch (_) {}
    _outSub = null;
    try {
      _errSub?.cancel();
    } catch (_) {}
    _errSub = null;
    try {
      _proc?.cancel();
    } catch (_) {}
    _proc = null;
  }

  @override
  void cancel() {
    _token = Object();
    try {
      _restartDebounce?.cancel();
    } catch (_) {}
    _restartDebounce = null;
    _stop();
    _lifecycleWorker?.dispose();
    _lifecycleWorker = null;
  }
}
