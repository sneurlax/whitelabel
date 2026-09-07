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

  test('a failure rolls back content, ownership, and created directories', () {
    f.configurator().plan().apply();
    final state = f.read('.whitelabel/state.json');
    final plan = f.configurator().plan(
      overrides: {'name': 'Other'},
      generatedFiles: [GeneratedFile('new/deep/output', utf8.encode('extra'))],
    );
    expect(
      () => plan.apply(
        onWrite: (change) {
          if (change.path == 'new/deep/output') {
            throw StateError('simulated failure');
          }
        },
      ),
      throwsStateError,
    );
    expect(f.read('lib/brand.g.dart'), 'const name = "Example";\n');
    expect(f.read('.whitelabel/state.json'), state);
    expect(Directory(p.join(f.project.path, 'new')).existsSync(), isFalse);
    expect(
      Directory(p.join(f.project.path, '.whitelabel/transaction')).existsSync(),
      isFalse,
    );
  });
  for (final fail in [false, true]) {
    test(
      'staging protects parent-private files (failure: $fail)',
      () {
        final c = f.configurator(
          manifest: f.manifest(
            files: [
              {
                'source': 'templates/brand.tmpl',
                'destination': 'private/config',
              },
            ],
          ),
        );
        final original = f.output('private/config', 'old confidential value');
        expect(
          Process.runSync('chmod', ['700', original.parent.path]).exitCode,
          0,
        );
        expect(Process.runSync('chmod', ['644', original.path]).exitCode, 0);
        final plan = c.plan(overwrite: true);
        void apply() => plan.apply(
          onWrite: (change) {
            if (change.path != 'private/config') return;
            final staging = Directory(
              p.join(f.project.path, '.whitelabel/transaction'),
            );
            expect(staging.statSync().mode & 0x1ff, 0x1c0);
            expect(
              File(p.join(staging.path, '0.old')).readAsStringSync(),
              'old confidential value',
            );
            if (fail) throw StateError('stop');
          },
        );
        if (fail) {
          expect(apply, throwsStateError);
          expect(original.readAsStringSync(), 'old confidential value');
        } else {
          apply();
          expect(original.readAsStringSync(), contains('Example'));
        }
        expect(
          Directory(
            p.join(f.project.path, '.whitelabel/transaction'),
          ).existsSync(),
          isFalse,
        );
      },
      skip: Platform.isWindows ? 'POSIX permission bits' : false,
    );
  }

  test('rollback restores deleted obsolete files', () {
    f.configurator().plan().apply();
    final manifest = f.manifest(
      files: [
        {'source': 'templates/brand.tmpl', 'destination': 'new.dart'},
      ],
    );
    expect(
      () => f
          .configurator(manifest: manifest)
          .plan()
          .apply(
            onWrite: (change) {
              if (change.action == 'delete') throw StateError('stop');
            },
          ),
      throwsStateError,
    );
    expect(f.read('lib/brand.g.dart'), contains('Example'));
  });

  Future<void> interrupt() async {
    final manifestPath = p.join(f.sources.path, 'brand.yaml');
    File(manifestPath).writeAsStringSync(jsonEncode(f.data()));
    final script = File(p.join(f.temp.path, 'interrupt.dart'))
      ..writeAsStringSync('''
import 'dart:io';
import 'package:whitelabel/whitelabel.dart';
void main(List<String> args) {
  final manifest=BrandManifest.load(args[0]);
  Configurator(projectRoot:args[1],manifest:manifest).plan(overrides:{'name':'Interrupted'}).apply(onWrite:(change) { exit(99); });
}
''');
    final result = await Process.run(Platform.resolvedExecutable, [
      '--packages=${p.absolute('.dart_tool/package_config.json')}',
      script.path,
      manifestPath,
      f.project.path,
    ]);
    expect(result.exitCode, 99, reason: result.stderr.toString());
  }

  test(
    'recovery secures legacy staging even if recovery fails',
    () async {
      f.configurator().plan().apply();
      await interrupt();
      final staging = Directory(
        p.join(f.project.path, '.whitelabel/transaction'),
      );
      final backup = File(p.join(staging.path, '0.old'));
      final bytes = backup.readAsBytesSync();
      backup.writeAsStringSync('corrupt');
      expect(Process.runSync('chmod', ['775', staging.path]).exitCode, 0);
      expect(() => recoverConfiguration(f.project.path), throwsStateError);
      expect(staging.statSync().mode & 0x1ff, 0x1c0);
      backup.writeAsBytesSync(bytes);
      recoverConfiguration(f.project.path);
      expect(f.read('lib/brand.g.dart'), contains('Example'));
      expect(staging.existsSync(), isFalse);
    },
    skip: Platform.isWindows ? 'POSIX permission bits' : false,
  );

  test('an interrupted apply is recoverable', () async {
    f.configurator().plan().apply();
    final state = f.read('.whitelabel/state.json');
    await interrupt();
    expect(f.read('lib/brand.g.dart'), contains('Interrupted'));
    expect(() => f.configurator().plan(), throwsStateError);
    recoverConfiguration(f.project.path);
    expect(f.read('lib/brand.g.dart'), contains('Example'));
    expect(f.read('.whitelabel/state.json'), state);
    expect(f.configurator().plan().hasChanges, isFalse);
    recoverConfiguration(f.project.path);
  });
  test(
    'recovery replaces leftover read-only restore staging',
    () async {
      f.configurator().plan().apply();
      await interrupt();
      final temporary = f.output(
        '.whitelabel/transaction/restore.tmp',
        'partial restore',
      );
      expect(Process.runSync('chmod', ['444', temporary.path]).exitCode, 0);
      recoverConfiguration(f.project.path);
      expect(f.read('lib/brand.g.dart'), contains('Example'));
    },
    skip: Platform.isWindows ? 'POSIX read-only staging' : false,
  );

  test(
    'legacy journals without permission fields remain recoverable',
    () async {
      f.configurator().plan().apply();
      await interrupt();
      final file = File(
        p.join(f.project.path, '.whitelabel/transaction/journal.json'),
      );
      final journal =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final change in journal['changes'] as List) {
        (change as Map)
          ..remove('before_mode')
          ..remove('after_mode');
      }
      file.writeAsStringSync(jsonEncode(journal));
      recoverConfiguration(f.project.path);
      expect(f.read('lib/brand.g.dart'), contains('Example'));
    },
  );
  test(
    'recovery preserves permission edits after interruption',
    () async {
      f.configurator().plan().apply();
      await interrupt();
      final output = File(p.join(f.project.path, 'lib/brand.g.dart'));
      expect(Process.runSync('chmod', ['700', output.path]).exitCode, 0);
      expect(() => recoverConfiguration(f.project.path), throwsStateError);
      expect(output.statSync().mode & 0x1ff, 0x1c0);
      expect(output.readAsStringSync(), contains('Interrupted'));
    },
    skip: Platform.isWindows ? 'POSIX permissions' : false,
  );

  test('recovery refuses edits made after interruption', () async {
    f.configurator().plan().apply();
    await interrupt();
    f.output('lib/brand.g.dart', 'new human edit');
    expect(() => recoverConfiguration(f.project.path), throwsStateError);
    expect(f.read('lib/brand.g.dart'), 'new human edit');
    expect(
      File(
        p.join(f.project.path, '.whitelabel/transaction/journal.json'),
      ).existsSync(),
      isTrue,
    );
  });
  test('recovery verifies backups before writing', () async {
    f.configurator().plan().apply();
    await interrupt();
    f.output('.whitelabel/transaction/0.old', 'corrupt');
    expect(() => recoverConfiguration(f.project.path), throwsStateError);
    expect(f.read('lib/brand.g.dart'), contains('Interrupted'));
  });
  test(
    'recovery rejects special staging entries',
    () {
      final directory = Directory(
        p.join(f.project.path, '.whitelabel/transaction'),
      )..createSync(recursive: true);
      final pipe = p.join(directory.path, 'unexpected');
      expect(Process.runSync('mkfifo', [pipe]).exitCode, 0);
      expect(
        () => recoverConfiguration(f.project.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(FileSystemEntity.typeSync(pipe), FileSystemEntityType.pipe);
    },
    skip: Platform.isWindows ? 'POSIX named pipes' : false,
  );

  test('recovery discards staging without a journal', () {
    f.output('.whitelabel/transaction/0.new', 'staging');
    recoverConfiguration(f.project.path);
    expect(
      Directory(p.join(f.project.path, '.whitelabel/transaction')).existsSync(),
      isFalse,
    );
  });
  test('recover rejects a non-directory transaction path', () {
    f.output('.whitelabel/transaction', 'junk');
    expect(
      () => recoverConfiguration(f.project.path),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.message,
          'message',
          contains('not a directory'),
        ),
      ),
    );
    expect(() => f.configurator().plan(), throwsStateError);
  });
  test('a failed recovery keeps the journal and stays retryable', () async {
    f.configurator().plan().apply();
    await interrupt();
    final stray = Directory(
      p.join(f.project.path, '.whitelabel/transaction/stray'),
    )..createSync();
    expect(
      () => recoverConfiguration(f.project.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      File(
        p.join(f.project.path, '.whitelabel/transaction/journal.json'),
      ).existsSync(),
      isTrue,
    );
    stray.deleteSync();
    recoverConfiguration(f.project.path);
    expect(f.read('lib/brand.g.dart'), contains('Example'));
    expect(
      Directory(p.join(f.project.path, '.whitelabel/transaction')).existsSync(),
      isFalse,
    );
  });
  test('partial staging deletion after rollback remains recoverable', () async {
    f.configurator().plan().apply();
    await interrupt();
    final path = p.join(
      f.project.resolveSymbolicLinksSync(),
      '.whitelabel/transaction',
    );
    final overrides = _FailCleanup(path);
    expect(
      () => IOOverrides.runWithIOOverrides(
        () => recoverConfiguration(f.project.path),
        overrides,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(overrides.failed, isTrue);
    expect(f.read('lib/brand.g.dart'), contains('Example'));
    expect(() => f.configurator().plan(), throwsStateError);
    recoverConfiguration(f.project.path);
    expect(Directory(path).existsSync(), isFalse);
    expect(f.configurator().plan().hasChanges, isFalse);
  });

  test('journal path traversal is rejected', () {
    f.output(
      '.whitelabel/transaction/journal.json',
      jsonEncode({
        'schema_version': 1,
        'changes': [
          {
            'path': '../victim',
            'action': 'create',
            'before_sha256': null,
            'after_sha256': null,
          },
        ],
        'created_directories': <String>[],
      }),
    );
    final victim = File(p.join(f.temp.path, 'victim'))
      ..writeAsStringSync('protected');
    expect(() => recoverConfiguration(f.project.path), throwsFormatException);
    expect(victim.readAsStringSync(), 'protected');
  });
  test('another process cannot apply while the project is locked', () async {
    f.output('.whitelabel/lock', '');
    final lock = File(
      p.join(f.project.path, '.whitelabel/lock'),
    ).openSync(mode: FileMode.append);
    lock.lockSync(FileLock.exclusive);
    try {
      final manifestPath = p.join(f.sources.path, 'brand.yaml');
      File(manifestPath).writeAsStringSync(jsonEncode(f.data()));
      final result = await Process.run(Platform.resolvedExecutable, [
        p.absolute('bin/whitelabel.dart'),
        'configure',
        '-m',
        manifestPath,
        '-p',
        f.project.path,
      ]);
      expect(result.exitCode, isNot(0), reason: result.stdout.toString());
      expect(result.stderr.toString(), contains('project lock'));
      expect(
        File(p.join(f.project.path, 'lib/brand.g.dart')).existsSync(),
        isFalse,
      );
    } finally {
      lock.unlockSync();
      lock.closeSync();
    }
  });
}

final class _FailCleanup extends IOOverrides {
  _FailCleanup(this.path);
  final String path;
  bool failed = false;

  @override
  Directory createDirectory(String path) {
    final directory = super.createDirectory(path);
    if (path != this.path) return directory;
    return _PartialDelete(directory, () => failed = true);
  }
}

class _PartialDelete implements Directory {
  _PartialDelete(this.directory, this.onFailure);
  final Directory directory;
  final void Function() onFailure;

  @override
  String get path => directory.path;
  @override
  bool existsSync() => directory.existsSync();
  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => directory.listSync(recursive: recursive, followLinks: followLinks);
  @override
  void deleteSync({bool recursive = false}) {
    for (final file in directory.listSync()) {
      if (file is File && file.path.endsWith('.old')) file.deleteSync();
    }
    onFailure();
    throw FileSystemException('Simulated partial staging deletion', path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
