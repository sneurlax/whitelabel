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

  test('plan writes nothing', () {
    final plan = f.configurator().plan();
    expect(plan.changes.single.action, 'create');
    expect(plan.changes.single.diff, contains('+const name = "Example";'));
    expect(f.project.listSync(), isEmpty);
  });
  test('apply is idempotent and brands switch cleanly', () {
    f.configurator().plan().apply();
    final first = f.read('lib/brand.g.dart');
    final unchanged = f.configurator().plan();
    expect(unchanged.hasChanges, isFalse);
    unchanged.apply();
    f
        .configurator(
          manifest: f.manifest(brand: 'other', name: 'Other'),
        )
        .plan()
        .apply();
    expect(f.read('lib/brand.g.dart'), 'const name = "Other";\n');
    f.configurator().plan().apply();
    expect(f.read('lib/brand.g.dart'), first);
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
  test('unowned and edited files require overwrite', () {
    f.output('lib/brand.g.dart', 'custom');
    expect(() => f.configurator().plan(), throwsStateError);
    f.configurator().plan(overwrite: true).apply();
    f.output('lib/brand.g.dart', 'edited');
    expect(() => f.configurator().plan(), throwsStateError);
    expect(f.read('lib/brand.g.dart'), 'edited');
  });
  test('stale plans are rejected', () {
    final plan = f.configurator().plan();
    f.output('lib/brand.g.dart', 'new work');
    expect(() => plan.apply(), throwsStateError);
    expect(f.read('lib/brand.g.dart'), 'new work');
    File(p.join(f.project.path, 'lib/brand.g.dart')).deleteSync();
    final a = f.configurator().plan();
    final b = f.configurator(manifest: f.manifest(name: 'Other')).plan();
    a.apply();
    expect(() => b.apply(), throwsStateError);
  });
  test('platform selection limits inputs and outputs', () {
    final manifest = f.manifest(
      platforms: ['android', 'ios'],
      files: [
        {'source': 'templates/brand.tmpl', 'destination': 'shared.dart'},
        {
          'source': 'templates/android',
          'destination': 'android/name',
          'platforms': ['android'],
        },
        {
          'source': 'templates/ios',
          'destination': 'ios/name',
          'platforms': ['ios'],
        },
      ],
    );
    f.input('templates/android', '{{text:name}}');
    f.configurator(manifest: manifest).plan(platforms: ['android']).apply();
    expect(File(p.join(f.project.path, 'ios/name')).existsSync(), isFalse);
    f.input('templates/ios', '{{text:name}}');
    f
        .configurator(manifest: manifest)
        .plan(platforms: ['ios'], overrides: {'name': 'iOS'})
        .apply();
    expect(f.read('android/name'), 'Example');
    expect(f.read('ios/name'), 'iOS');
    expect(
      () => f.configurator(manifest: manifest).plan(platforms: []),
      throwsFormatException,
    );
    expect(
      () => f.configurator(manifest: manifest).plan(platforms: ['web']),
      throwsFormatException,
    );
  });
  test('planning without a selection covers every declared platform', () {
    final manifest = f.manifest(
      platforms: ['android', 'ios'],
      files: [
        {
          'source': 'templates/android',
          'destination': 'android/name',
          'platforms': ['android'],
        },
        {
          'source': 'templates/ios',
          'destination': 'ios/name',
          'platforms': ['ios'],
        },
      ],
    );
    f.input('templates/android', 'a');
    f.input('templates/ios', 'i');
    f.configurator(manifest: manifest).plan().apply();
    expect(f.read('android/name'), 'a');
    expect(f.read('ios/name'), 'i');
  });
  test('prunes obsolete owned files only', () {
    f.input('assets/a.txt', 'A');
    f.input('assets/b.txt', 'B');
    final manifest = f.manifest(
      files: [
        {'source': 'assets', 'destination': 'assets/brand', 'mode': 'copy'},
      ],
    );
    f.configurator(manifest: manifest).plan().apply();
    f.output('assets/brand/user.txt', 'user');
    File(p.join(f.sources.path, 'assets/b.txt')).deleteSync();
    final plan = f.configurator(manifest: manifest).plan();
    expect(
      plan.changes.where((change) => change.action == 'delete').single.path,
      'assets/brand/b.txt',
    );
    plan.apply();
    expect(
      File(p.join(f.project.path, 'assets/brand/b.txt')).existsSync(),
      isFalse,
    );
    expect(f.read('assets/brand/user.txt'), 'user');
  });
  test('edited owned files are not pruned', () {
    f.configurator().plan().apply();
    f.output('lib/brand.g.dart', 'edited');
    final manifest = f.manifest(
      files: [
        {'source': 'templates/brand.tmpl', 'destination': 'new.dart'},
      ],
    );
    expect(() => f.configurator(manifest: manifest).plan(), throwsStateError);
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
  test('generated files get the same checks', () {
    final plan = f.configurator().plan(
      generatedFiles: [
        GeneratedFile('generated/data.json', utf8.encode('{"enabled":true}')),
      ],
    );
    plan.apply();
    expect(jsonDecode(f.read('generated/data.json')), {'enabled': true});
    expect(
      () => f.configurator().plan(
        generatedFiles: [GeneratedFile('lib/brand.g.dart', [])],
      ),
      throwsStateError,
    );
    expect(() => GeneratedFile('../outside', []), throwsFormatException);
  });
  test('overrides must be declared and stay data', () {
    expect(
      () => f.configurator().plan(overrides: {'typo': 'value'}),
      throwsFormatException,
    );
    f.configurator().plan(overrides: {'name': r'A $quoted "name"'}).apply();
    expect(f.read('lib/brand.g.dart'), contains(r'\$quoted'));
  });
  test('relative roots work', () {
    Configurator(
      projectRoot: p.relative(f.project.path),
      sourceRoot: p.relative(f.sources.path),
      manifest: f.manifest(),
    ).plan().apply();
    expect(f.read('lib/brand.g.dart'), contains('Example'));
  });
  test('nested project roots work', () {
    final nested = Directory(p.join(f.project.path, 'apps', 'sample'))
      ..createSync(recursive: true);
    Configurator(
      projectRoot: nested.path,
      manifest: f.manifest(),
    ).plan().apply();
    expect(File(p.join(nested.path, 'lib/brand.g.dart')).existsSync(), isTrue);
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
  test('a missing copy source leaves outputs untouched', () {
    f.input('images/logo.txt', 'image');
    final manifest = f.manifest(
      files: [
        {'source': 'images', 'destination': 'images', 'mode': 'copy'},
      ],
    );
    f.configurator(manifest: manifest).plan().apply();
    Directory(p.join(f.sources.path, 'images')).deleteSync(recursive: true);
    expect(
      () => f.configurator(manifest: manifest).plan(),
      throwsA(isA<FileSystemException>()),
    );
    expect(f.read('images/logo.txt'), 'image');
  });
}
