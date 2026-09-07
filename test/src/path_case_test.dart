import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:whitelabel/whitelabel.dart';

import '../support/fixture.dart';

void main() {
  late Fixture f;
  setUp(() => f = Fixture());
  tearDown(() => f.dispose());

  for (final mode in ['template', 'copy']) {
    test('$mode files reject differently cased parents', () {
      final c = f.configurator(
        manifest: f.manifest(
          files: [
            {
              'source': 'templates/brand.tmpl',
              'destination': 'Out/Assets/a',
              'mode': mode,
            },
            {
              'source': 'templates/brand.tmpl',
              'destination': 'Out/assets/b',
              'mode': mode,
            },
          ],
        ),
      );
      expect(() => c.plan(), throwsStateError);
      expect(f.project.listSync(), isEmpty);
    });
  }
  test('generated files share case checks with manifest files', () {
    final c = f.configurator(
      manifest: f.manifest(
        files: [
          {'source': 'templates/brand.tmpl', 'destination': 'Out/Assets/a'},
        ],
      ),
    );
    expect(
      () => c.plan(generatedFiles: [GeneratedFile('Out/assets/b', [])]),
      throwsStateError,
    );
    expect(f.project.listSync(), isEmpty);
  });
  test('copied directories cannot alias implicit file parents', () {
    Directory(p.join(f.sources.path, 'empty')).createSync();
    final c = f.configurator(
      manifest: f.manifest(
        files: [
          {'source': 'empty', 'destination': 'Out/Assets', 'mode': 'copy'},
          {'source': 'templates/brand.tmpl', 'destination': 'out/Assets/a'},
        ],
      ),
    );
    expect(() => c.plan(), throwsStateError);
    expect(f.project.listSync(), isEmpty);
  });
  test('repeated identically spelled parents are allowed', () {
    Directory(p.join(f.sources.path, 'empty')).createSync();
    final c = f.configurator(
      manifest: f.manifest(
        files: [
          {'source': 'empty', 'destination': 'Out/Assets', 'mode': 'copy'},
          {'source': 'templates/brand.tmpl', 'destination': 'Out/Assets/a'},
          {
            'source': 'templates/brand.tmpl',
            'destination': 'Out/Assets/deeper/b',
          },
        ],
      ),
    );
    final plan = c.plan(generatedFiles: [GeneratedFile('Out/Assets/c', [])]);
    expect(plan.changes, hasLength(3));
    expect(plan.directories.single.path, 'Out/Assets');
  });
}
