import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:whitelabel/whitelabel.dart';

import '../support/fixture.dart';
import '../support/process.dart';

void main() {
  late Fixture f;
  late Configurator c;
  setUp(() {
    f = Fixture();
    Directory(
      p.join(f.sources.path, 'assets/empty'),
    ).createSync(recursive: true);
    c = f.configurator(
      manifest: f.manifest(
        files: [
          {'source': 'assets', 'destination': 'copied', 'mode': 'copy'},
        ],
      ),
    );
  });
  tearDown(() => f.dispose());
  Directory output(String relative) =>
      Directory(p.join(f.project.path, relative));
  void chmod(String path, String mode) =>
      expect(Process.runSync('chmod', [mode, path]).exitCode, 0);

  test('copies empty directories, reports them, and is idempotent', () {
    final plan = c.plan();
    expect(plan.directories.map((entry) => entry.path), [
      'copied',
      'copied/empty',
    ]);
    expect(plan.toJson()['directories'], hasLength(2));
    expect(
      plan.directories.last.diff,
      contains('Create directory copied/empty'),
    );
    expect(output('copied').existsSync(), isFalse);
    plan.apply();
    expect(output('copied/empty').existsSync(), isTrue);
    expect(c.plan().hasChanges, isFalse);
    // Directory-only repairs still apply even when the ownership bytes match.
    output('copied/empty').deleteSync();
    expect(c.plan().hasChanges, isTrue);
    c.plan().apply();
    expect(output('copied/empty').existsSync(), isTrue);
  });
  test('existing matching directories and unrelated files are retained', () {
    c.plan().apply();
    f.output('copied/unmanaged', 'keep');
    c.plan().apply();
    expect(f.read('copied/unmanaged'), 'keep');
    f.configurator().plan().apply();
    expect(output('copied/empty').existsSync(), isTrue);
    expect(f.read('copied/unmanaged'), 'keep');
  });
  test('an empty directory cannot collide with a generated file', () {
    expect(
      () => c.plan(generatedFiles: [GeneratedFile('copied/empty', [])]),
      throwsStateError,
    );
    expect(
      () => c.plan(generatedFiles: [GeneratedFile('copied', [])]),
      throwsStateError,
    );
    expect(output('copied').existsSync(), isFalse);
  });
  test('a newly created destination makes an existing plan stale', () {
    final plan = c.plan();
    output('copied').createSync();
    expect(() => plan.apply(), throwsStateError);
    expect(output('copied/empty').existsSync(), isFalse);
  });
  test('failed application removes all newly copied empty directories', () {
    expect(
      () => c.plan().apply(onWrite: (_) => throw StateError('stop')),
      throwsStateError,
    );
    expect(output('copied').existsSync(), isFalse);
    expect(output('.whitelabel/transaction').existsSync(), isFalse);
  });

  group(
    'POSIX directory permissions',
    () {
      test(
        'private directories protect contents before and after installation',
        () {
          f.input('assets/private/token', 'secret');
          chmod(p.join(f.sources.path, 'assets/private'), '700');
          chmod(p.join(f.sources.path, 'assets/private/token'), '644');
          final plan = c.plan();
          expect(
            plan.directories
                .singleWhere((d) => d.path == 'copied/private')
                .mode,
            0x1c0,
          );
          plan.apply(
            onWrite: (change) {
              if (change.path == 'copied/private/token') {
                expect(output('copied/private').statSync().mode & 0x1ff, 0x1c0);
              }
            },
          );
          expect(output('copied/private').statSync().mode & 0x1ff, 0x1c0);
          expect(f.read('copied/private/token'), 'secret');
          expect(c.plan().hasChanges, isFalse);
        },
      );
      test('existing directory modes are never adopted through overwrite', () {
        chmod(p.join(f.sources.path, 'assets'), '700');
        output('copied').createSync();
        chmod(output('copied').path, '755');
        for (final overwrite in [false, true]) {
          expect(() => c.plan(overwrite: overwrite), throwsStateError);
        }
        expect(output('copied').statSync().mode & 0x1ff, 0x1ed);
        expect(output('copied/empty').existsSync(), isFalse);
      });
      test(
        'directory permissions are captured and checked for stale plans',
        () {
          chmod(p.join(f.sources.path, 'assets'), '700');
          final plan = c.plan();
          chmod(p.join(f.sources.path, 'assets'), '755');
          plan.apply();
          expect(output('copied').statSync().mode & 0x1ff, 0x1c0);
          chmod(p.join(f.sources.path, 'assets'), '700');
          final stale = c.plan();
          chmod(output('copied').path, '755');
          expect(() => stale.apply(), throwsStateError);
        },
      );
      test(
        'read-only source directories are populated before final permissions',
        () {
          f.input('assets/readonly/file', 'contents');
          final source = p.join(f.sources.path, 'assets/readonly');
          chmod(source, '500');
          addTearDown(() {
            chmod(source, '700');
            if (output('copied/readonly').existsSync()) {
              chmod(output('copied/readonly').path, '700');
            }
          });
          c.plan().apply();
          expect(f.read('copied/readonly/file'), 'contents');
          expect(output('copied/readonly').statSync().mode & 0x1ff, 0x140);
          expect(c.plan().hasChanges, isFalse);
          // A failed update under an existing read-only directory must remain
          // recoverable, including already-installed outputs elsewhere.
          chmod(source, '700');
          f.input('assets/readonly/file', 'changed');
          f.input('assets/a-first', 'first');
          chmod(source, '500');
          expect(() => c.plan().apply(), throwsA(isA<FileSystemException>()));
          expect(f.read('copied/readonly/file'), 'contents');
          expect(
            File(p.join(f.project.path, 'copied/a-first')).existsSync(),
            isFalse,
          );
          expect(output('.whitelabel/transaction').existsSync(), isFalse);
        },
      );
      test(
        'interrupted directory copies recover even after final read-only modes',
        () async {
          f.input('assets/readonly/file', 'contents');
          final manifest = f.input(
            'brand.json',
            jsonEncode(
              f.data(
                files: [
                  {'source': 'assets', 'destination': 'copied', 'mode': 'copy'},
                ],
              ),
            ),
          );
          final script = File(p.join(f.temp.path, 'interrupt.dart'))
            ..writeAsStringSync('''
import 'dart:io';
import 'package:whitelabel/whitelabel.dart';
void main(List<String> args) {
  Configurator(projectRoot: args[1], manifest: BrandManifest.load(args[0]))
    .plan().apply(onWrite: (change) { if (change.path == '.whitelabel/state.json') exit(99); });
}
''');
          final result = await runDart(script, [manifest.path, f.project.path]);
          expect(result.exitCode, 99, reason: result.stderr.toString());
          chmod(output('copied/readonly').path, '500');
          recoverConfiguration(f.project.path);
          expect(output('copied').existsSync(), isFalse);
          expect(output('.whitelabel/transaction').existsSync(), isFalse);
        },
      );
    },
    skip: Platform.isWindows ? 'POSIX permission bits' : false,
  );
}
