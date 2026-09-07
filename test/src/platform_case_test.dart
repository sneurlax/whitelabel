import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture.dart';

void main() {
  late Fixture f;
  setUp(() => f = Fixture());
  tearDown(() => f.dispose());

  for (final copyDirectory in [false, true]) {
    test(
      'retained platform files constrain parent casing (directory: $copyDirectory)',
      () {
        Directory(p.join(f.sources.path, 'empty')).createSync();
        final c = f.configurator(
          manifest: f.manifest(
            platforms: ['android', 'ios'],
            files: [
              {
                'source': 'templates/brand.tmpl',
                'destination': 'Out/android/a',
                'platforms': ['android'],
              },
              if (copyDirectory)
                {
                  'source': 'empty',
                  'destination': 'out/ios',
                  'mode': 'copy',
                  'platforms': ['ios'],
                }
              else
                {
                  'source': 'templates/brand.tmpl',
                  'destination': 'out/ios/a',
                  'platforms': ['ios'],
                },
            ],
          ),
        );
        c.plan(platforms: ['android']).apply();
        final state = f.read('.whitelabel/state.json');
        expect(() => c.plan(platforms: ['ios']), throwsStateError);
        expect(f.read('.whitelabel/state.json'), state);
        expect(f.read('Out/android/a'), contains('Example'));
        expect(
          Directory(p.join(f.project.path, 'Out/ios')).existsSync(),
          isFalse,
        );
      },
    );
  }
  test('incremental platform runs can share identically spelled parents', () {
    final c = f.configurator(
      manifest: f.manifest(
        platforms: ['android', 'ios'],
        files: [
          {
            'source': 'templates/brand.tmpl',
            'destination': 'Out/android/a',
            'platforms': ['android'],
          },
          {
            'source': 'templates/brand.tmpl',
            'destination': 'Out/ios/a',
            'platforms': ['ios'],
          },
        ],
      ),
    );
    c.plan(platforms: ['android']).apply();
    c.plan(platforms: ['ios']).apply();
    expect(f.read('Out/android/a'), contains('Example'));
    expect(f.read('Out/ios/a'), contains('Example'));
    expect(c.plan().hasChanges, isFalse);
  });
}
