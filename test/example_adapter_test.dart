import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:whitelabel/whitelabel.dart';

import '../example/adapter/adapter.dart';

void main() {
  late Directory project;
  setUp(() => project = Directory.systemTemp.createTempSync('notes-adapter-'));
  tearDown(() => project.deleteSync(recursive: true));

  BrandManifest manifest({
    bool export = true,
    String url = 'https://example.com',
  }) {
    return BrandManifest.parse(
      jsonEncode({
        'schema_version': 1,
        'brand': 'notes',
        'variables': {
          'name': 'Notes "quoted" \$name ✓',
          'service_url': url,
          'features': [if (export) 'export'],
        },
        'files': [
          {'source': 'templates/pubspec.tmpl', 'destination': 'pubspec.yaml'},
          {'source': 'templates/main.tmpl', 'destination': 'bin/main.dart'},
        ],
      }),
      sourceDirectory: p.absolute('example/adapter'),
    );
  }

  test('generated program runs and disabling export removes its asset', () {
    planNotes(projectRoot: project.path, manifest: manifest()).apply();
    final result = Process.runSync(Platform.resolvedExecutable, [
      p.join(project.path, 'bin/main.dart'),
    ], stdoutEncoding: utf8);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(jsonDecode(result.stdout.toString()), {
      'name': 'Notes "quoted" \$name ✓',
      'service': 'https://example.com',
      'export': true,
    });
    planNotes(
      projectRoot: project.path,
      manifest: manifest(export: false),
    ).apply();
    expect(
      File(p.join(project.path, 'assets/export.txt')).existsSync(),
      isFalse,
    );
    final switched = Process.runSync(Platform.resolvedExecutable, [
      p.join(project.path, 'bin/main.dart'),
    ], stdoutEncoding: utf8);
    expect(switched.exitCode, 0, reason: switched.stderr.toString());
    expect(jsonDecode(switched.stdout.toString())['export'], isFalse);
  });

  test('invalid settings write nothing', () {
    expect(
      () => planNotes(
        projectRoot: project.path,
        manifest: manifest(url: 'http://example.com'),
      ),
      throwsFormatException,
    );
    expect(project.listSync(), isEmpty);
  });

  test('generated files keep ownership protection', () {
    planNotes(projectRoot: project.path, manifest: manifest()).apply();
    final file = File(p.join(project.path, 'lib/settings.g.dart'));
    file.writeAsStringSync('manual edit');
    expect(
      () => planNotes(projectRoot: project.path, manifest: manifest()),
      throwsStateError,
    );
    expect(file.readAsStringSync(), 'manual edit');
  });
}
