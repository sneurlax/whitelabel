import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:whitelabel/whitelabel.dart';

import '../support/fixture.dart';

void main() {
  late Fixture f;
  setUp(() => f = Fixture());
  tearDown(() => f.dispose());

  test('generated files may be the whole output set', () {
    final manifest = f.manifest(files: []);
    expect(
      () => f.configurator(manifest: manifest).plan(),
      throwsFormatException,
    );
    f
        .configurator(manifest: manifest)
        .plan(
          generatedFiles: [
            GeneratedFile('config.json', utf8.encode('{"name":"Example"}')),
          ],
        )
        .apply();
    expect(jsonDecode(f.read('config.json')), {'name': 'Example'});
  });
  test('cycles, alias bombs, and oversized manifests are rejected', () {
    final recursive = <Object?>[];
    recursive.add(recursive);
    expect(() => encodeTemplateValue('dart', recursive), throwsFormatException);
    final yaml = StringBuffer(
      'schema_version: 1\nbrand: example\nvariables:\n  a: &a [1, 1, 1, 1, 1, 1, 1, 1, 1, 1]\n',
    );
    var previous = 'a';
    for (var index = 0; index < 5; index++) {
      final name = 'v$index';
      yaml.writeln(
        '  $name: &$name [${List.filled(10, '*$previous').join(', ')}]',
      );
      previous = name;
    }
    yaml.writeln('files: [{source: a, destination: b}]');
    expect(() => BrandManifest.parse(yaml.toString()), throwsFormatException);
    expect(
      () => BrandManifest.parse('x' * (1024 * 1024 + 1)),
      throwsFormatException,
    );
  });
  test('recovery cannot reenter an active apply', () {
    final plan = f.configurator().plan();
    plan.apply(
      onWrite: (change) {
        expect(() => recoverConfiguration(f.project.path), throwsStateError);
      },
    );
    expect(f.read('lib/brand.g.dart'), contains('Example'));
  });
  test(
    'rollback keeps POSIX modes',
    () {
      final original = f.output('lib/brand.g.dart', 'private existing value');
      expect(Process.runSync('chmod', ['600', original.path]).exitCode, 0);
      final plan = f.configurator().plan(overwrite: true);
      expect(
        () => plan.apply(
          onWrite: (change) {
            if (change.path == 'lib/brand.g.dart') {
              expect(original.statSync().mode & 0x1ff, 0x180);
              expect(
                File(
                      p.join(f.project.path, '.whitelabel/transaction/0.old'),
                    ).statSync().mode &
                    0x1ff,
                0x180,
              );
              throw StateError('rollback');
            }
          },
        ),
        throwsStateError,
      );
      expect(original.readAsStringSync(), 'private existing value');
      expect(original.statSync().mode & 0x1ff, 0x180);
    },
    skip: Platform.isWindows ? 'POSIX file modes' : false,
  );
  test(
    'a directory junction cannot redirect output on Windows',
    () {
      final target = Directory(p.join(f.temp.path, 'outside'))..createSync();
      final victim = File(p.join(target.path, 'brand.g.dart'))
        ..writeAsStringSync('outside');
      final result = Process.runSync('cmd.exe', [
        '/d',
        '/c',
        'mklink',
        '/J',
        p.join(f.project.path, 'lib'),
        target.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(
        () => f.configurator().plan(overwrite: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(victim.readAsStringSync(), 'outside');
    },
    skip: Platform.isWindows ? false : 'Windows directory junction',
  );
  test('binary outputs are exact and immutable', () {
    final bytes = <int>[0, 255, 128, 1, 10, 13];
    final generated = GeneratedFile('assets/binary', bytes);
    bytes[0] = 99;
    final plan = f.configurator().plan(generatedFiles: [generated]);
    final change = plan.changes.firstWhere(
      (change) => change.path == 'assets/binary',
    );
    expect(change.diff, contains('Binary file'));
    expect(() => change.after![0] = 7, throwsUnsupportedError);
    plan.apply();
    expect(File(p.join(f.project.path, 'assets/binary')).readAsBytesSync(), [
      0,
      255,
      128,
      1,
      10,
      13,
    ]);
  });
  test(
    'a symlink substituted after planning is rejected at apply',
    () {
      final plan = f.configurator().plan();
      final outside = Directory(p.join(f.temp.path, 'outside'))..createSync();
      Link(p.join(f.project.path, 'lib')).createSync(outside.path);
      expect(() => plan.apply(), throwsA(isA<FileSystemException>()));
      expect(outside.listSync(), isEmpty);
    },
    skip: Platform.isWindows ? 'POSIX symlink' : false,
  );
  test(
    'a replaced project root is rejected at apply',
    () {
      final plan = f.configurator().plan();
      final original = f.project.path;
      f.project.renameSync(p.join(f.temp.path, 'original_project'));
      final outside = Directory(p.join(f.temp.path, 'other_project'))
        ..createSync();
      Link(original).createSync(outside.path);
      expect(() => plan.apply(), throwsA(isA<FileSystemException>()));
      expect(outside.listSync(), isEmpty);
    },
    skip: Platform.isWindows ? 'POSIX symlink' : false,
  );
}
