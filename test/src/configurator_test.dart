import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture.dart';

void main() {
  late Fixture f;
  setUp(() => f = Fixture());
  tearDown(() => f.dispose());

  test('plan writes nothing', () {
    final plan = f.configurator().plan();
    expect(plan.changes.single.action, 'create');
    expect(f.project.listSync(), isEmpty);
  });
  test('a missing template leaves outputs untouched', () {
    f.output('lib/brand.g.dart', 'hand written');
    File(p.join(f.sources.path, 'templates/brand.tmpl')).deleteSync();
    expect(
      () => f.configurator().plan(overwrite: true),
      throwsA(isA<FileSystemException>()),
    );
    expect(f.read('lib/brand.g.dart'), 'hand written');
    expect(
      Directory(p.join(f.project.path, '.whitelabel')).existsSync(),
      isFalse,
    );
  });
  test('any missing input fails before writes', () {
    final manifest = f.manifest(
      files: [
        {'source': 'templates/brand.tmpl', 'destination': 'a.dart'},
        {'source': 'missing', 'destination': 'b.dart'},
      ],
    );
    expect(
      () => f.configurator(manifest: manifest).plan(),
      throwsA(isA<FileSystemException>()),
    );
    expect(f.project.listSync(), isEmpty);
  });
  test('detects duplicate, case-folded, and nested collisions', () {
    for (final second in ['a.dart', 'A.dart', 'a.dart/child']) {
      final manifest = f.manifest(
        files: [
          {'source': 'templates/brand.tmpl', 'destination': 'a.dart'},
          {'source': 'templates/brand.tmpl', 'destination': second},
        ],
      );
      expect(() => f.configurator(manifest: manifest).plan(), throwsStateError);
    }
  });
  test('corrupt state is rejected', () {
    f.output(
      '.whitelabel/state.json',
      '{"schema_version":1,"files":{"../victim":{}}}',
    );
    expect(() => f.configurator().plan(), throwsFormatException);
  });
  test(
    'input and output symlinks cannot escape roots',
    () {
      final outside = Directory(p.join(f.temp.path, 'outside'))..createSync();
      File(p.join(outside.path, 'brand.g.dart')).writeAsStringSync('outside');
      Link(p.join(f.project.path, 'lib')).createSync(outside.path);
      expect(
        () => f.configurator().plan(overwrite: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        File(p.join(outside.path, 'brand.g.dart')).readAsStringSync(),
        'outside',
      );
      Link(p.join(f.project.path, 'lib')).deleteSync();
      final input = File(p.join(f.sources.path, 'templates/brand.tmpl'))
        ..deleteSync();
      Link(input.path).createSync(p.join(outside.path, 'brand.g.dart'));
      expect(
        () => f.configurator().plan(),
        throwsA(isA<FileSystemException>()),
      );
    },
    skip: Platform.isWindows ? 'POSIX symlink' : false,
  );
  test(
    'dangling output symlinks are refused',
    () {
      Directory(p.join(f.project.path, 'lib')).createSync();
      Link(
        p.join(f.project.path, 'lib/brand.g.dart'),
      ).createSync(p.join(f.temp.path, 'absent'));
      expect(
        () => f.configurator().plan(),
        throwsA(isA<FileSystemException>()),
      );
    },
    skip: Platform.isWindows ? 'POSIX symlink' : false,
  );
}
