import 'dart:convert';
import 'dart:io';

import 'package:process_run/shell.dart';

class LocalCommandProcess {
  final Stream<String> stdoutLines;
  final Stream<String> stderrLines;
  final Future<int> exitCode;
  final Future<void> done;
  final void Function() cancel;

  const LocalCommandProcess({
    required this.stdoutLines,
    required this.stderrLines,
    required this.exitCode,
    required this.done,
    required this.cancel,
  });
}

class LocalShellService {
  LocalCommandProcess startCommand({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    String? stdin,
  }) {
    final out = ShellLinesController(encoding: utf8);
    final err = ShellLinesController(encoding: utf8);

    final stdinStream = (stdin == null)
        ? null
        : Stream<List<int>>.fromIterable([utf8.encode(stdin)]);

    final shell = Shell(
      workingDirectory: workingDirectory,
      stdin: stdinStream,
      stdout: out.sink,
      stderr: err.sink,
      verbose: false,
      throwOnError: false,
    );

    final runFuture = shell.runExecutableArguments(executable, arguments).catchError((
      e,
      st,
    ) {
      // `process_run` throws ShellException when a process is killed (e.g. when
      // we cancel a long-lived `tail -F`). Treat that as a normal termination
      // so callers don't see noisy "Unhandled Exception" logs.
      final msg = e.toString();
      final isKilled =
          msg.contains('Killed by framework') ||
          msg.contains('killed by framework');
      return ProcessResult(0, isKilled ? 143 : 1, '', msg);
    });

    void cancel() {
      try {
        shell.kill();
      } catch (_) {}
    }

    return LocalCommandProcess(
      stdoutLines: out.stream,
      stderrLines: err.stream,
      done: runFuture.then((_) {}),
      exitCode: runFuture.then((r) => r.exitCode),
      cancel: cancel,
    );
  }

  Future<ProcessResult> run({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    bool throwOnError = false,
  }) async {
    final shell = Shell(
      workingDirectory: workingDirectory,
      verbose: false,
      throwOnError: throwOnError,
    );
    return shell.runExecutableArguments(executable, arguments);
  }
}
