import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  final cli = p.absolute('bin/whitelabel.dart');
  late Fixture f;
  late String manifest;
  setUp(() {
    f = Fixture();
    manifest = p.join(f.sources.path, 'brand.yaml');
    File(manifest).writeAsStringSync(jsonEncode(f.data()));
  });
  tearDown(() => f.dispose());
  Future<ProcessResult> run(List<String> args, {String? workingDirectory}) =>
      Process.run(Platform.resolvedExecutable, [
        cli,
        ...args,
      ], workingDirectory: workingDirectory);

  test('help works without required arguments', () async {
    for (final args in [
      ['--help'],
      ['plan', '--help'],
      ['configure', '--help'],
      ['recover', '--help'],
    ]) {
      expect((await run(args)).exitCode, 0);
    }
  });
  test('bad arguments write nothing', () async {
    expect((await run(['configure'])).exitCode, 64);
    expect(
      (await run([
        'configure',
        '-m',
        manifest,
        '-p',
        f.project.path,
        '--define',
        'missing=value',
      ])).exitCode,
      1,
    );
    expect(
      (await run([
        'configure',
        '-m',
        manifest,
        '-p',
        f.project.path,
        'junk',
      ])).exitCode,
      64,
    );
    expect(
      (await run([
        'plan',
        '-m',
        manifest,
        '-p',
        f.project.path,
        '--',
        '--json',
      ])).exitCode,
      64,
    );
    expect(f.project.listSync(), isEmpty);
  });
  test(
    'directory-only copies appear in CLI plans and are configured',
    () async {
      Directory(
        p.join(f.sources.path, 'assets/empty'),
      ).createSync(recursive: true);
      File(manifest).writeAsStringSync(
        jsonEncode(
          f.data(
            files: [
              {'source': 'assets', 'destination': 'copied', 'mode': 'copy'},
            ],
          ),
        ),
      );
      final arguments = ['-m', manifest, '-p', f.project.path];
      final plan = await run(['plan', ...arguments, '--json']);
      expect(plan.exitCode, 0, reason: plan.stderr.toString());
      expect(jsonDecode(plan.stdout.toString())['directories'], hasLength(2));
      final diff = await run(['plan', ...arguments, '--diff']);
      expect(diff.exitCode, 0, reason: diff.stderr.toString());
      expect(diff.stdout, contains('Create directory copied/empty'));
      expect(f.project.listSync(), isEmpty);
      final configured = await run(['configure', ...arguments]);
      expect(configured.exitCode, 0, reason: configured.stderr.toString());
      expect(configured.stdout, contains('CREATE directory copied/empty'));
      expect(
        Directory(p.join(f.project.path, 'copied/empty')).existsSync(),
        isTrue,
      );
    },
  );

  test('relative roots and --json work from another directory', () async {
    final plan = await run([
      'plan',
      '-m',
      'sources/brand.yaml',
      '-p',
      'project',
      '--json',
    ], workingDirectory: f.temp.path);
    expect(plan.exitCode, 0, reason: plan.stderr.toString());
    expect(
      (jsonDecode(plan.stdout.toString())['files'] as List).single['action'],
      'create',
    );
    expect(f.project.listSync(), isEmpty);
    final applied = await run([
      'configure',
      '-m',
      'sources/brand.yaml',
      '-p',
      'project',
      '--define',
      'name=Other, Inc.',
    ], workingDirectory: f.temp.path);
    expect(applied.exitCode, 0, reason: applied.stderr.toString());
    expect(f.read('lib/brand.g.dart'), 'const name = "Other, Inc.";\n');
  });
  test('plan --diff prints whole-file diffs without writing', () async {
    final result = await run([
      'plan',
      '-m',
      manifest,
      '-p',
      f.project.path,
      '--diff',
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout.toString(), contains('+++ b/lib/brand.g.dart'));
    expect(result.stdout.toString(), contains('+const name = "Example";'));
    expect(f.project.listSync(), isEmpty);
  });
  test('configure --overwrite adopts an edited output', () async {
    final applied = await run([
      'configure',
      '-m',
      manifest,
      '-p',
      f.project.path,
    ]);
    expect(applied.exitCode, 0, reason: applied.stderr.toString());
    f.output('lib/brand.g.dart', 'human edit');
    final refused = await run([
      'configure',
      '-m',
      manifest,
      '-p',
      f.project.path,
    ]);
    expect(refused.exitCode, 1);
    expect(f.read('lib/brand.g.dart'), 'human edit');
    final adopted = await run([
      'configure',
      '-m',
      manifest,
      '-p',
      f.project.path,
      '--overwrite',
    ]);
    expect(adopted.exitCode, 0, reason: adopted.stderr.toString());
    expect(f.read('lib/brand.g.dart'), 'const name = "Example";\n');
  });
  test('recover discards an interrupted configure', () async {
    f.output('.whitelabel/transaction/0.new', 'staging');
    final result = await run(['recover', '-p', f.project.path]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout.toString(), contains('Recovery complete.'));
    expect(
      Directory(p.join(f.project.path, '.whitelabel/transaction')).existsSync(),
      isFalse,
    );
  });
  test(
    'compiled executable configures a project',
    () async {
      final executable = p.join(
        f.temp.path,
        Platform.isWindows ? 'whitelabel.exe' : 'whitelabel',
      );
      final compiled = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        cli,
        '-o',
        executable,
      ]);
      expect(compiled.exitCode, 0, reason: compiled.stderr.toString());
      final result = await Process.run(executable, [
        'configure',
        '-m',
        manifest,
        '-p',
        f.project.path,
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(f.read('lib/brand.g.dart'), contains('Example'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
