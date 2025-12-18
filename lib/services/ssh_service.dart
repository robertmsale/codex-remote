import 'dart:async';

import '../rinf/rust_ssh_service.dart';
import 'field_execd_client.dart';

class SshCommandResult {
  final String stdout;
  final String stderr;
  final int? exitCode;

  const SshCommandResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });
}

class SshCommandProcess {
  final Stream<String> stdoutLines;
  final Stream<String> stderrLines;
  final Future<int?> exitCode;
  final Future<void> done;
  final void Function() cancel;

  const SshCommandProcess({
    required this.stdoutLines,
    required this.stderrLines,
    required this.exitCode,
    required this.done,
    required this.cancel,
  });
}

class SshService {
  final FieldExecdClient? _daemon;

  SshService({FieldExecdClient? daemon}) : _daemon = daemon;

  static const defaultConnectTimeout = Duration(seconds: 10);
  static const defaultAuthTimeout = Duration(seconds: 10);
  static const defaultCommandTimeout = Duration(minutes: 2);
  static const defaultWatchdogCommandTimeout = Duration(seconds: 5);

  static String _normalizeSshError(Object e) {
    final msg = e.toString();
    if (msg.contains('Password prompt cancelled') ||
        msg.contains('Password prompt timed out')) {
      return 'SSH authentication failed (password auth is not used). Verify your SSH key is installed and accepted by the server.';
    }
    if (msg.contains('SSH key authentication failed')) {
      return 'SSH key authentication failed. Verify your SSH key is installed and accepted by the server.';
    }
    if (msg.contains('SSH private key is invalid') ||
        msg.contains('passphrase is wrong')) {
      return 'SSH private key is invalid or passphrase is wrong.';
    }
    return msg;
  }

  static bool _shouldResetPoolForErrorMessage(String msg) {
    final m = msg.toLowerCase();
    if (m.contains('ssh command timeout')) return true;
    if (m.contains('ssh connect timeout')) return true;
    if (m.contains('brokenpipe') || m.contains('broken pipe')) return true;
    if (m.contains('connection reset') ||
        m.contains('connection aborted') ||
        m.contains('not connected') ||
        m.contains('unexpected eof')) {
      return true;
    }
    if (m.contains('senderror') || m.contains('channelsenderror')) return true;
    return false;
  }

  Future<void> resetAllConnections({String? reason}) async {
    final daemon = _daemon;
    if (daemon != null && FieldExecdClient.supported) {
      try {
        await daemon.request(
          method: 'ssh.reset_all',
          params: <String, Object?>{'reason': reason},
        );
      } catch (_) {
        // Best-effort. Reset is primarily a recovery mechanism.
      }
      return;
    }
    try {
      await RustSshService.resetAllConnections(reason: reason);
    } catch (_) {
      // Best-effort. Reset is primarily a recovery mechanism.
    }
  }

  Future<String> runCommand({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? privateKeyPassphrase,
    required String command,
    Duration connectTimeout = defaultConnectTimeout,
    Duration authTimeout = defaultAuthTimeout,
    Duration timeout = defaultCommandTimeout,
    int retries = 1,
  }) async {
    final res = await runCommandWithResult(
      host: host,
      port: port,
      username: username,
      password: password,
      privateKeyPem: privateKeyPem,
      privateKeyPassphrase: privateKeyPassphrase,
      command: command,
      connectTimeout: connectTimeout,
      authTimeout: authTimeout,
      timeout: timeout,
      retries: retries,
    );
    return res.stdout;
  }

  Future<SshCommandResult> runCommandWithResult({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? privateKeyPassphrase,
    required String command,
    String? stdin,
    Duration connectTimeout = defaultConnectTimeout,
    Duration authTimeout = defaultAuthTimeout,
    Duration timeout = defaultCommandTimeout,
    int retries = 1,
  }) async {
    SshCommandResult last = const SshCommandResult(stdout: '', stderr: '', exitCode: 1);
    Object? lastErr;

    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        if (stdin != null && stdin.isNotEmpty) {
          throw UnsupportedError('stdin is not supported via RustSshService.runCommandWithResult');
        }

        final daemon = _daemon;
        if (daemon != null && FieldExecdClient.supported) {
          final target = _daemonTarget(
            host: host,
            port: port,
            username: username,
            password: password,
            privateKeyPem: privateKeyPem,
            privateKeyPassphrase: privateKeyPassphrase,
          );
          final res = await daemon.request(
            method: 'ssh.exec',
            params: <String, Object?>{
              'target': target,
              'command': command,
              'connect_timeout_ms': connectTimeout.inMilliseconds,
              'command_timeout_ms': timeout.inMilliseconds,
            },
          );
          return SshCommandResult(
            stdout: (res['stdout'] as String?) ?? '',
            stderr: (res['stderr'] as String?) ?? '',
            exitCode: (res['exit_code'] as num?)?.toInt(),
          );
        }

        final res = await RustSshService.runCommandWithResult(
          host: host,
          port: port,
          username: username,
          command: command,
          privateKeyPemOverride: privateKeyPem,
          privateKeyPassphrase: privateKeyPassphrase,
          connectTimeout: connectTimeout,
          commandTimeout: timeout,
          passwordProvider: password == null ? null : () async => password,
        );

        return SshCommandResult(
          stdout: res.stdout,
          stderr: res.stderr,
          exitCode: res.exitCode,
        );
      } catch (e) {
        final normalized = _normalizeSshError(e);
        if (_shouldResetPoolForErrorMessage(normalized) && attempt < retries) {
          await resetAllConnections(reason: 'retry:$normalized');
        }
        lastErr = StateError(normalized);
        last = SshCommandResult(stdout: '', stderr: normalized, exitCode: 1);
        if (attempt >= retries) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }

    if (lastErr != null) {
      // ignore: only_throw_errors
      throw lastErr;
    }
    return last;
  }

  Future<SshCommandProcess> startCommand({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? privateKeyPassphrase,
    required String command,
    String? stdin,
    Duration connectTimeout = defaultConnectTimeout,
    Duration authTimeout = defaultAuthTimeout,
    int retries = 1,
  }) async {
    if (stdin != null && stdin.isNotEmpty) {
      throw UnsupportedError('stdin is not supported for startCommand');
    }

    Object? lastErr;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final daemon = _daemon;
        if (daemon != null && FieldExecdClient.supported) {
          final target = _daemonTarget(
            host: host,
            port: port,
            username: username,
            password: password,
            privateKeyPem: privateKeyPem,
            privateKeyPassphrase: privateKeyPassphrase,
          );
          final stream = await daemon.startStream(
            method: 'ssh.start',
            params: <String, Object?>{
              'target': target,
              'command': command,
              'connect_timeout_ms': connectTimeout.inMilliseconds,
            },
          );
          return SshCommandProcess(
            stdoutLines: stream.stdoutLines,
            stderrLines: stream.stderrLines,
            exitCode: stream.exitCode.then((v) => v),
            done: stream.done,
            cancel: () => daemon.cancelStream(stream.streamId),
          );
        }

        final proc = await RustSshService.startCommand(
          host: host,
          port: port,
          username: username,
          command: command,
          privateKeyPemOverride: privateKeyPem,
          privateKeyPassphrase: privateKeyPassphrase,
          connectTimeout: connectTimeout,
          passwordProvider: password == null ? null : () async => password,
        );

        return SshCommandProcess(
          stdoutLines: proc.stdoutLines,
          stderrLines: proc.stderrLines,
          exitCode: proc.exitCode,
          done: proc.done,
          cancel: proc.cancel,
        );
      } catch (e) {
        final normalized = _normalizeSshError(e);
        lastErr = StateError(normalized);
        if (_shouldResetPoolForErrorMessage(normalized) && attempt < retries) {
          await resetAllConnections(reason: 'retry:$normalized');
        }
        if (attempt >= retries) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    // ignore: only_throw_errors
    throw lastErr ?? StateError('SSH start failed');
  }

  Future<void> writeRemoteFile({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? privateKeyPassphrase,
    required String remotePath,
    required String contents,
    Duration connectTimeout = defaultConnectTimeout,
    Duration authTimeout = defaultAuthTimeout,
    Duration timeout = defaultCommandTimeout,
    int retries = 1,
  }) async {
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final daemon = _daemon;
        if (daemon != null && FieldExecdClient.supported) {
          final target = _daemonTarget(
            host: host,
            port: port,
            username: username,
            password: password,
            privateKeyPem: privateKeyPem,
            privateKeyPassphrase: privateKeyPassphrase,
          );
          await daemon.request(
            method: 'ssh.write_file',
            params: <String, Object?>{
              'target': target,
              'remote_path': remotePath,
              'contents': contents,
              'connect_timeout_ms': connectTimeout.inMilliseconds,
              'command_timeout_ms': timeout.inMilliseconds,
            },
          );
          return;
        }

        await RustSshService.writeRemoteFile(
          host: host,
          port: port,
          username: username,
          remotePath: remotePath,
          contents: contents,
          privateKeyPemOverride: privateKeyPem,
          privateKeyPassphrase: privateKeyPassphrase,
          connectTimeout: connectTimeout,
          commandTimeout: timeout,
          passwordProvider: password == null ? null : () async => password,
        );
        return;
      } catch (e) {
        final normalized = _normalizeSshError(e);
        if (_shouldResetPoolForErrorMessage(normalized) && attempt < retries) {
          await resetAllConnections(reason: 'retry:$normalized');
        }
        if (attempt >= retries) {
          throw StateError(normalized);
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  Future<void> installPublicKey({
    required String userAtHost,
    required int port,
    required String password,
    required String privateKeyPem,
    String? privateKeyPassphrase,
    String comment = 'field-exec',
  }) {
    final daemon = _daemon;
    if (daemon != null && FieldExecdClient.supported) {
      return daemon.request(
        method: 'ssh.install_public_key',
        params: <String, Object?>{
          'user_at_host': userAtHost,
          'port': port,
          'password': password,
          'private_key_pem': privateKeyPem,
          'private_key_passphrase': privateKeyPassphrase,
          'comment': comment,
        },
      ).then((_) => null);
    }
    return RustSshService.installPublicKey(
      userAtHost: userAtHost,
      port: port,
      password: password,
      privateKeyPem: privateKeyPem,
      privateKeyPassphrase: privateKeyPassphrase,
      comment: comment,
    );
  }

  static Map<String, Object?> _daemonTarget({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? privateKeyPassphrase,
  }) {
    final pem = (privateKeyPem ?? '').trim();
    if (pem.isNotEmpty) {
      return <String, Object?>{
        'host': host,
        'port': port,
        'username': username,
        'auth': <String, Object?>{
          'kind': 'key',
          'private_key_pem': pem,
          'private_key_passphrase': privateKeyPassphrase,
        },
      };
    }

    final pwd = (password ?? '').trim();
    if (pwd.isEmpty) {
      throw StateError('SSH key required. Set up a key first.');
    }

    return <String, Object?>{
      'host': host,
      'port': port,
      'username': username,
      'auth': <String, Object?>{
        'kind': 'password',
        'password': pwd,
      },
    };
  }
}
