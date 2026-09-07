import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Bound subprocess probes so a blocking filesystem regression cannot hang CI.
Future<ProcessResult> runDart(File script, List<String> arguments) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    '--packages=${p.absolute('.dart_tool/package_config.json')}',
    script.path,
    ...arguments,
  ]);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  try {
    final code = await process.exitCode.timeout(const Duration(seconds: 15));
    return ProcessResult(process.pid, code, await output, await errors);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await Future.wait([output, errors]);
    rethrow;
  }
}
