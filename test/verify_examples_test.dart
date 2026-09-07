import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final verifier = p.absolute('tool/verify_examples.dart');
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('verifier-test-'));
  tearDown(() => root.deleteSync(recursive: true));

  Future<ProcessResult> run(List<String> args) =>
      Process.run(Platform.resolvedExecutable, [verifier, ...args]);

  void expectUsageError(ProcessResult result, String message) {
    expect(result.exitCode, 64, reason: result.stderr.toString());
    expect(result.stderr.toString(), startsWith('error: '));
    expect(result.stderr.toString(), contains(message));
    expect(result.stderr.toString(), isNot(contains('Unhandled exception')));
  }

  for (final args in [
    ['--reproducble'],
    ['--build'],
    ['unexpected'],
    ['--', '--reproducible'],
  ]) {
    test('invalid verifier request $args fails before running', () async {
      final result = await run(args);
      expect(result.exitCode, 64, reason: result.stderr.toString());
      expect(result.stderr.toString(), startsWith('error: '));
      expect(result.stdout.toString(), isNot(contains('Dart example passed')));
      expect(root.listSync(), isEmpty);
    });
  }

  test('separated report arguments are parsed and validated', () async {
    final result = await run(['--report', p.join(root.path, 'report.json')]);
    expectUsageError(result, '--report requires --reproducible');
    expect(root.listSync(), isEmpty);
  });

  test('invalid build options do not claim the report', () async {
    final report = p.join(root.path, 'report.json');
    final result = await run([
      '--reproducible',
      '--flutter',
      '--report=$report',
    ]);
    expectUsageError(result, 'requires --build');
    expect(root.listSync(), isEmpty);
  });

  test('duplicate report options do not claim either destination', () async {
    final result = await run([
      '--reproducible',
      '--report=${p.join(root.path, 'a.json')}',
      '--report=${p.join(root.path, 'b.json')}',
    ]);
    expectUsageError(result, 'Duplicate --report');
    expect(root.listSync(), isEmpty);
  });

  test('an existing report is preserved', () async {
    final report = File(p.join(root.path, 'report.json'))
      ..writeAsStringSync('previous report');
    final result = await run(['--reproducible', '--report=${report.path}']);
    expectUsageError(result, 'already exists');
    expect(report.readAsStringSync(), 'previous report');
  });

  test('a missing report parent is a clean argument error', () async {
    final result = await run([
      '--reproducible',
      '--report=${p.join(root.path, 'absent', 'report.json')}',
    ]);
    expectUsageError(result, 'Cannot create report');
    expect(root.listSync(), isEmpty);
  });

  test(
    'a report created during verification is not overwritten',
    () async {
      final report = File(p.join(root.path, 'report.json'));
      final process = await Process.start(Platform.resolvedExecutable, [
        verifier,
        '--reproducible',
        '--report',
        report.path,
      ]);
      final errors = process.stderr.transform(utf8.decoder).join();
      final output = <String>[];
      final wrote = Completer<void>();
      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            output.add(line);
            if (!wrote.isCompleted && line.startsWith('Generated:')) {
              report.writeAsStringSync('another writer');
              wrote.complete();
            }
          });
      addTearDown(() {
        process.kill();
      });
      final code = await process.exitCode;
      await stdoutDone;
      expect(wrote.isCompleted, isTrue, reason: output.join('\n'));
      expect(code, 64, reason: await errors);
      expect(await errors, contains('Cannot create report exclusively'));
      expect(report.readAsStringSync(), 'another writer');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('an empty report path is a clean argument error', () async {
    final result = await run(['--reproducible', '--report=']);
    expectUsageError(result, 'must not be empty');
    expect(root.listSync(), isEmpty);
  });
}
