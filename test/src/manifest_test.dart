import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:whitelabel/whitelabel.dart';

void main() {
  Map<String, Object?> valid() => {
    'schema_version': 1,
    'brand': 'sample',
    'variables': {
      'title': 'A title',
      'options': {'enabled': true, 'count': 3},
    },
    'platforms': ['android', 'web'],
    'files': [
      {'source': 'templates/config.tmpl', 'destination': 'lib/config.g.dart'},
    ],
  };
  BrandManifest parse(Map<String, Object?> value) =>
      BrandManifest.parse(jsonEncode(value));
  test('parses nested variables into immutable data', () {
    final manifest = parse(valid());
    expect(manifest.brand, 'sample');
    expect(manifest.variables['options'], {'enabled': true, 'count': 3});
    expect(
      () => manifest.variables['title'] = 'changed',
      throwsUnsupportedError,
    );
    expect(
      () => (manifest.variables['options'] as Map)['count'] = 4,
      throwsUnsupportedError,
    );
    expect(() => manifest.files.clear(), throwsUnsupportedError);
  });
  test('platforms is optional', () {
    final value = valid()..remove('platforms');
    expect(parse(value).platforms, isEmpty);
  });
  test('load rejects an oversized manifest before reading it', () {
    final directory = Directory.systemTemp.createTempSync(
      'whitelabel-manifest-',
    );
    try {
      final file = File(p.join(directory.path, 'brand.yaml'))
        ..writeAsStringSync('brand: ${'x' * (1024 * 1024)}');
      expect(() => BrandManifest.load(file.path), throwsFormatException);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
  for (final entry in <String, Object?>{
    'schema_version': 2,
    'brand': '../other',
    'variables': [],
    'platforms': 'android',
    'files': 'invalid',
    'unknown_key': true,
  }.entries) {
    test('rejects invalid ${entry.key}', () {
      expect(
        () => parse(valid()..[entry.key] = entry.value),
        throwsFormatException,
      );
    });
  }
  test('rejects null optional fields and duplicate or unknown platforms', () {
    for (final value in [
      null,
      ['android', 'android'],
      ['unsupported'],
    ]) {
      expect(
        () => parse(valid()..['platforms'] = value),
        throwsFormatException,
      );
    }
    expect(() => parse(valid()..['variables'] = null), throwsFormatException);
  });
  test('rejects reserved variables and undeclared file platforms', () {
    expect(
      () => parse(valid()..['variables'] = {'brand': 'override'}),
      throwsFormatException,
    );
    expect(
      () => parse(
        valid()
          ..['files'] = [
            {
              'source': 'a',
              'destination': 'b',
              'platforms': ['ios'],
            },
          ],
      ),
      throwsFormatException,
    );
  });
  test('rejects unknown file keys and explicit null modes', () {
    for (final extra in [
      {'typo': true},
      {'mode': null},
    ]) {
      expect(
        () => parse(
          valid()
            ..['files'] = [
              {'source': 'a', 'destination': 'b', ...extra},
            ],
        ),
        throwsFormatException,
      );
    }
  });
  for (final path in [
    '../outside',
    '/absolute',
    r'C:\outside',
    r'folder\file',
    'a/../b',
    'a//b',
    'a/./b',
    'NUL.txt',
    r'CONOUT$',
    'LONGFI~1',
    'café.txt',
    'cafe\u0301.txt',
    'name.',
    'name ',
    'a:stream',
    '.git/config',
    '.whitelabel/state.json',
    '.dart_tool/config',
  ]) {
    test('rejects unsafe output $path', () {
      expect(
        () => parse(
          valid()
            ..['files'] = [
              {'source': 'a', 'destination': path},
            ],
        ),
        throwsFormatException,
      );
    });
  }
  test('rejects non-finite YAML values and recursive aliases', () {
    expect(
      () => BrandManifest.parse('''
schema_version: 1
brand: example
variables: {number: .nan}
files: [{source: a, destination: b}]
'''),
      throwsFormatException,
    );
    expect(
      () => BrandManifest.parse('''
schema_version: 1
brand: example
variables: &cycle {nested: *cycle}
files: [{source: a, destination: b}]
'''),
      throwsA(isA<Exception>()),
    );
  });
}
