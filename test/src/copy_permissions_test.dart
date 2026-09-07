import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:whitelabel/whitelabel.dart';

import '../support/fixture.dart';

void main() {
  group(
    'POSIX copy permissions',
    () {
      late Fixture f;
      late File source;
      late Configurator c;
      setUp(() {
        f = Fixture();
        source = f.input('assets/script', '#!/bin/sh\nexit 0\n');
        c = f.configurator(
          manifest: f.manifest(
            files: [
              {'source': 'assets', 'destination': 'copied', 'mode': 'copy'},
            ],
          ),
        );
      });
      tearDown(() => f.dispose());
      void chmod(File file, String mode) =>
          expect(Process.runSync('chmod', [mode, file.path]).exitCode, 0);
      File output() => File(p.join(f.project.path, 'copied/script'));

      for (final mode in [0x1ed, 0x180, 0x124]) {
        test('new copies preserve mode ${mode.toRadixString(8)}', () {
          chmod(source, mode.toRadixString(8));
          c.plan().apply();
          expect(output().statSync().mode & 0x1ff, mode);
          expect(output().readAsBytesSync(), source.readAsBytesSync());
          expect(c.plan().hasChanges, isFalse);
        });
      }
      test('source mode changes are applied even when bytes are unchanged', () {
        chmod(source, '600');
        c.plan().apply();
        chmod(source, '755');
        final plan = c.plan();
        expect(plan.hasChanges, isTrue);
        expect(plan.changes.single.diff, contains('0600 -> 0755'));
        plan.apply();
        expect(output().statSync().mode & 0x1ff, 0x1ed);
        expect(c.plan().hasChanges, isFalse);
      });
      test('plans retain the captured source mode', () {
        chmod(source, '600');
        final plan = c.plan();
        chmod(source, '755');
        plan.apply();
        expect(output().statSync().mode & 0x1ff, 0x180);
      });
      test(
        'manual permission edits require overwrite and stale plans fail',
        () {
          chmod(source, '600');
          c.plan().apply();
          final plan = c.plan();
          chmod(output(), '644');
          expect(() => plan.apply(), throwsStateError);
          expect(() => c.plan(), throwsStateError);
          c.plan(overwrite: true).apply();
          expect(output().statSync().mode & 0x1ff, 0x180);
        },
      );
      test('failed mode-only updates roll back permissions', () {
        chmod(source, '600');
        c.plan().apply();
        chmod(source, '755');
        expect(
          () => c.plan().apply(onWrite: (_) => throw StateError('stop')),
          throwsStateError,
        );
        expect(output().statSync().mode & 0x1ff, 0x180);
      });
      test('single-file copies preserve private permissions', () {
        chmod(source, '600');
        f
            .configurator(
              manifest: f.manifest(
                files: [
                  {
                    'source': 'assets/script',
                    'destination': 'single',
                    'mode': 'copy',
                  },
                ],
              ),
            )
            .plan()
            .apply();
        expect(
          File(p.join(f.project.path, 'single')).statSync().mode & 0x1ff,
          0x180,
        );
      });
      test('adopting a copy as a template keeps the adopted permissions', () {
        chmod(source, '600');
        c.plan().apply();
        chmod(output(), '644');
        final template = f.configurator(
          manifest: f.manifest(
            files: [
              {'source': 'assets/script', 'destination': 'copied/script'},
            ],
          ),
        );
        template.plan(overwrite: true).apply();
        expect(output().statSync().mode & 0x1ff, 0x1a4);
        expect(template.plan().hasChanges, isFalse);
      });
      test('legacy inventories without modes remain usable', () {
        chmod(source, '600');
        c.plan().apply();
        final state = File(p.join(f.project.path, '.whitelabel/state.json'));
        final data =
            jsonDecode(state.readAsStringSync()) as Map<String, dynamic>;
        for (final record in (data['files'] as Map).values) {
          (record as Map).remove('mode');
        }
        state.writeAsStringSync(jsonEncode(data));
        c.plan().apply();
        expect(output().statSync().mode & 0x1ff, 0x180);
        expect(c.plan().hasChanges, isFalse);
      });
    },
    skip: Platform.isWindows ? 'POSIX permission bits' : false,
  );
}
