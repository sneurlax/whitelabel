import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:whitelabel/whitelabel.dart';

/// Run from the package root. Pass --flutter to also verify the Flutter
/// example, and --build to build it for the host desktop.
Future<void> main(List<String> args) async {
  final repository = Directory.current.path;
  final flutter = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final temporary = Directory.systemTemp.createTempSync('whitelabel-examples-');
  Future<void> run(
    String executable,
    List<String> arguments,
    String cwd,
  ) async {
    final result = await Process.start(
      executable,
      arguments,
      workingDirectory: cwd,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await result.exitCode;
    if (code != 0) {
      throw ProcessException(executable, arguments, 'exit code $code', code);
    }
  }

  try {
    final dartApp = Directory(p.join(temporary.path, 'dart_app'))..createSync();
    final configurator = Configurator(
      projectRoot: dartApp.path,
      manifest: BrandManifest.load(
        p.join(repository, 'example/dart_app/brand.yaml'),
      ),
    );
    configurator.plan().apply();
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/main.dart'],
      workingDirectory: dartApp.path,
      stdoutEncoding: utf8,
    );
    if (result.exitCode != 0 ||
        jsonDecode(result.stdout.toString())['brand'] != 'sample_cli') {
      throw StateError('Dart example failed: ${result.stdout}${result.stderr}');
    }
    const switchedName = 'Other Notes \u2713';
    configurator.plan(overrides: {'name': switchedName}).apply();
    final switched = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/main.dart'],
      workingDirectory: dartApp.path,
      stdoutEncoding: utf8,
    );
    if (switched.exitCode != 0 ||
        jsonDecode(switched.stdout.toString())['name'] != switchedName) {
      throw StateError('Dart example switch failed');
    }
    stdout.writeln('Dart example passed.');
    if (args.contains('--flutter')) {
      final platform = Platform.isMacOS
          ? 'macos'
          : Platform.isWindows
          ? 'windows'
          : 'linux';
      final flutterApp = p.join(temporary.path, 'flutter_app');
      await run(flutter, [
        'create',
        '--empty',
        '--project-name',
        'sample_notes',
        '--platforms=$platform',
        flutterApp,
      ], repository);
      final consumer = Configurator(
        projectRoot: flutterApp,
        manifest: BrandManifest.load(
          p.join(repository, 'example/flutter_app/brand.yaml'),
        ),
      );
      // Overwrite is safe: this script created the scaffold moments ago.
      consumer.plan(platforms: [platform], overwrite: true).apply();
      await run(flutter, ['pub', 'get'], flutterApp);
      await run(flutter, ['analyze'], flutterApp);
      await run(flutter, ['test'], flutterApp);
      consumer
          .plan(platforms: [platform], overrides: {'name': 'Other Notes'})
          .apply();
      await run(flutter, ['test'], flutterApp);
      if (args.contains('--build')) {
        await run(flutter, ['build', platform, '--release'], flutterApp);
      }
      stdout.writeln('Flutter example passed.');
    }
  } finally {
    temporary.deleteSync(recursive: true);
  }
}
