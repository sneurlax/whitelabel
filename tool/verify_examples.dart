import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:whitelabel/whitelabel.dart';

import 'artifact_manifest.dart';
import 'exclusive_file.dart';

/// Run from the package root. Pass --flutter to also verify the Flutter
/// example, and --build to build it for the host desktop. --reproducible
/// compares two CLI builds and, with --flutter --build, two clean app builds.
Future<void> main(List<String> args) async {
  try {
    await _run(args);
  } on ArgParserException catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 64;
  } on ArgumentError catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 64;
  }
}

Future<void> _run(List<String> args) async {
  final parser = ArgParser();
  for (final flag in [
    'flutter',
    'build',
    'reproducible',
    'aot',
    'keep-output',
    'help',
  ]) {
    parser.addFlag(flag, negatable: false);
  }
  // A multi-option lets us reject duplicates instead of silently taking the last.
  parser.addMultiOption('report', splitCommas: false);
  final options = parser.parse(args);
  if (options.rest.isNotEmpty) {
    throw ArgumentError('Unexpected arguments: ${options.rest.join(' ')}');
  }
  if (options['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }
  final repository = Directory.current.path;
  final flutter = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final reproducible = options['reproducible'] as bool;
  final aot = options['aot'] as bool;
  final useFlutter = options['flutter'] as bool;
  final build = options['build'] as bool;
  if (aot && !reproducible) {
    throw ArgumentError('--aot requires --reproducible');
  }
  if (build && !useFlutter) throw ArgumentError('--build requires --flutter');
  if (reproducible && useFlutter && !build) {
    throw ArgumentError('--reproducible --flutter also requires --build');
  }
  final reportArguments = options['report'] as List<String>;
  if (reportArguments.length > 1) throw ArgumentError('Duplicate --report');
  final reportPath = reportArguments.isEmpty ? null : reportArguments.single;
  if (reportPath != null) {
    if (!reproducible) throw ArgumentError('--report requires --reproducible');
    if (reportPath.isEmpty) {
      throw ArgumentError('Report destination must not be empty');
    }
    if (reportPath.contains('\x00')) {
      throw ArgumentError('Report path contains NUL');
    }
    if (FileSystemEntity.typeSync(reportPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw ArgumentError('Report destination already exists: $reportPath');
    }
    if (!File(reportPath).parent.existsSync()) {
      throw ArgumentError(
        'Cannot create report: parent does not exist: $reportPath',
      );
    }
  }
  final comparisons = <Map<String, Object?>>[];
  var matches = true;
  final temporary = Directory.systemTemp.createTempSync('whitelabel-examples-');
  void compare(
    String name,
    Map<String, String> first,
    Map<String, String> second,
  ) {
    final differences = artifactDifferences(first, second);
    matches = matches && differences.isEmpty;
    comparisons.add({
      'name': name,
      'first': first,
      'second': second,
      'differences': differences,
    });
    stdout.writeln(
      '$name: ${differences.isEmpty ? 'byte-identical' : 'DIFFERENT: ${differences.join(', ')}'}',
    );
  }

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
    if (reproducible) {
      final cliRoot = Directory(p.join(temporary.path, 'cli'))..createSync();
      final executable = p.join(
        cliRoot.path,
        aot
            ? 'whitelabel.aot'
            : Platform.isWindows
            ? 'whitelabel.exe'
            : 'whitelabel',
      );
      final runtime = p.join(
        p.dirname(Platform.resolvedExecutable),
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      );
      if (aot) {
        File(runtime).copySync(p.join(cliRoot.path, p.basename(runtime)));
      }
      await run(Platform.resolvedExecutable, [
        'compile',
        aot ? 'aot-snapshot' : 'exe',
        'bin/whitelabel.dart',
        '-o',
        executable,
      ], repository);
      final first = artifactManifest(cliRoot.path);
      File(executable).deleteSync();
      await run(Platform.resolvedExecutable, [
        'compile',
        aot ? 'aot-snapshot' : 'exe',
        'bin/whitelabel.dart',
        '-o',
        executable,
      ], repository);
      await run(aot ? p.join(cliRoot.path, p.basename(runtime)) : executable, [
        if (aot) executable,
        '--help',
      ], repository);
      compare(
        aot ? 'aot-cli-bundle' : 'compiled-cli',
        first,
        artifactManifest(cliRoot.path),
      );
    }
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
    if (reproducible) {
      final peer = Directory(p.join(temporary.path, 'independent-dart-app'))
        ..createSync();
      Configurator(
        projectRoot: peer.path,
        manifest: BrandManifest.load(
          p.join(repository, 'example/dart_app/brand.yaml'),
        ),
      ).plan(overrides: {'name': switchedName}).apply();
      // dart run leaves resolution noise in the configured app; ignore only
      // that, so unexpected extras still fail the comparison.
      bool noise(String path) =>
          path == '.whitelabel/lock' ||
          path == 'pubspec.lock' ||
          path == '.dart_tool' ||
          path.startsWith('.dart_tool/');
      final expected = artifactManifest(peer.path)
        ..removeWhere((path, _) => noise(path));
      final actual = artifactManifest(dartApp.path)
        ..removeWhere((path, _) => noise(path));
      compare('dart-generated-files-and-ownership', actual, expected);
    }
    if (useFlutter) {
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
      if (build) {
        await run(flutter, [
          'build',
          platform,
          '--release',
          '--no-pub',
        ], flutterApp);
        if (reproducible) {
          final product = _desktopProduct(flutterApp, platform);
          final first = artifactManifest(product);
          await run(flutter, ['clean'], flutterApp);
          await run(flutter, ['pub', 'get', '--enforce-lockfile'], flutterApp);
          await run(flutter, [
            'build',
            platform,
            '--release',
            '--no-pub',
          ], flutterApp);
          compare(
            'flutter-$platform-release',
            first,
            artifactManifest(_desktopProduct(flutterApp, platform)),
          );
        }
      }
      stdout.writeln('Flutter example passed.');
    }
    if (reportPath != null) {
      // Create only after verification, using exclusive creation and a retained
      // handle. A competing file or symlink is never overwritten or deleted.
      final bytes = utf8.encode(
        '${const JsonEncoder.withIndent('  ').convert({'dart': Platform.version, 'os': Platform.operatingSystem, 'workspace': temporary.path, 'scope': 'Same source paths, SDK and dependency lock; fresh compiler invocation and clean Flutter rebuild. No signature or content normalization.', 'comparisons': comparisons, 'matches': matches})}\n',
      );
      try {
        final report = ExclusiveFile(reportPath);
        try {
          report.write(bytes);
        } finally {
          report.close();
        }
      } on FileSystemException catch (error) {
        throw ArgumentError('${error.message}: $reportPath');
      }
      stdout.writeln('Report: $reportPath');
    }
    if (!matches) exitCode = 1;
  } finally {
    if (options['keep-output'] as bool) {
      stdout.writeln('Preserved verification output: ${temporary.path}');
    } else {
      temporary.deleteSync(recursive: true);
    }
  }
}

String _desktopProduct(String project, String platform) {
  final products = Directory(p.join(project, 'build', platform))
      .listSync(recursive: true, followLinks: false)
      .where(
        (entry) => platform == 'macos'
            ? entry is Directory &&
                  p.basename(entry.path) == 'sample_notes.app' &&
                  p.basename(p.dirname(entry.path)) == 'Release'
            : entry is File &&
                  p.basename(entry.path) ==
                      (platform == 'windows'
                          ? 'sample_notes.exe'
                          : 'sample_notes') &&
                  entry.path.toLowerCase().contains('release'),
      )
      .toList();
  if (products.length != 1) {
    throw StateError(
      'Expected one $platform release product; found ${products.length}',
    );
  }
  return platform == 'macos'
      ? products.single.path
      : p.dirname(products.single.path);
}
