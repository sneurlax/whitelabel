import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:whitelabel/whitelabel.dart';

void main() {
  for (final (name, before, after) in [
    ('LF', 'old\n', 'new\n'),
    ('CRLF', 'old\r\n', 'new\r\n'),
    ('mixed', 'one\r\ntwo\n', 'three\nfour\r\n'),
    ('line endings only', 'same\n', 'same\r\n'),
    ('unterminated', 'old', 'new'),
    ('trailing CR', 'old\r', 'new\r'),
    ('empty creation', null, ''),
    ('empty deletion', '', null),
    ('empty creation with spaces', null, ''),
    ('empty deletion with spaces', '', null),
    ('creation', null, 'new\r\n'),
    ('deletion', 'old\r\n', null),
  ]) {
    test('diff applies exact $name bytes', () async {
      final root = Directory.systemTemp.createTempSync('whitelabel-diff-');
      addTearDown(() => root.deleteSync(recursive: true));
      final path = name.endsWith('with spaces') ? 'empty file.txt' : 'file.txt';
      final file = File(p.join(root.path, path));
      if (before != null) file.writeAsStringSync(before);
      final change = FileChange(
        path,
        before == null ? null : utf8.encode(before),
        after == null ? null : utf8.encode(after),
      );
      final patch = File(p.join(root.path, 'change.patch'))
        ..writeAsStringSync(change.diff);
      // Git is also available on Windows CI; --binary keeps CRLF verbatim.
      final result = await Process.run('git', [
        'apply',
        '--no-index',
        '--binary',
        '--whitespace=nowarn',
        patch.path,
      ], workingDirectory: root.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      if (after == null) {
        expect(file.existsSync(), isFalse);
      } else {
        expect(file.readAsBytesSync(), utf8.encode(after));
      }
    });
  }
  for (final emptyFirst in [true, false]) {
    for (final emptyDelete in [true, false]) {
      for (final (operation, before, after) in [
        ('create', null, 'new\r\n'),
        ('replace', 'old\n', 'new\r\n'),
        ('delete', 'old\r\n', null),
        ('empty', 'old\n', ''),
      ]) {
        test(
          'batch: empty delete=$emptyDelete first=$emptyFirst plus $operation',
          () async {
            final root = Directory.systemTemp.createTempSync('diff-batch-');
            addTearDown(() => root.deleteSync(recursive: true));
            final empty = FileChange(
              'empty file',
              emptyDelete ? [] : null,
              emptyDelete ? null : [],
            );
            final text = FileChange(
              'text file',
              before == null ? null : utf8.encode(before),
              after == null ? null : utf8.encode(after),
            );
            final changes = emptyFirst ? [empty, text] : [text, empty];
            for (final change in changes) {
              if (change.before != null) {
                File(
                  p.join(root.path, change.path),
                ).writeAsBytesSync(change.before!);
              }
            }
            final patch = File(p.join(root.path, 'batch.patch'))
              ..writeAsStringSync(changes.map((change) => change.diff).join());
            final result = await Process.run('git', [
              'apply',
              '--no-index',
              '--binary',
              '--whitespace=nowarn',
              patch.path,
            ], workingDirectory: root.path);
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout}${result.stderr}',
            );
            for (final change in changes) {
              final file = File(p.join(root.path, change.path));
              expect(file.existsSync(), change.after != null);
              if (change.after != null) {
                expect(file.readAsBytesSync(), change.after);
              }
            }
          },
        );
      }
    }
  }
  for (final contents in ['', '#!/bin/sh\nexit 0\n']) {
    test(
      'executable addition retains Git mode (${contents.length} bytes)',
      () async {
        final root = Directory.systemTemp.createTempSync(
          'whitelabel-exec-diff-',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final patch = File(p.join(root.path, 'change.patch'))
          ..writeAsStringSync(
            FileChange(
              'script',
              null,
              utf8.encode(contents),
              afterMode: 0x1ed,
            ).diff,
          );
        final result = await Process.run('git', [
          'apply',
          '--no-index',
          patch.path,
        ], workingDirectory: root.path);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        final file = File(p.join(root.path, 'script'));
        expect(file.readAsBytesSync(), utf8.encode(contents));
        expect(file.statSync().mode & 0x49, 0x49);
      },
      skip: Platform.isWindows ? 'POSIX executable bits' : false,
    );
  }
}
