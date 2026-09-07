import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/exclusive_file.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('exclusive-report-'));
  tearDown(() => root.deleteSync(recursive: true));

  test('writes exact bytes to a Unicode path and closes only once', () {
    final path = p.join(root.path, 'report-é-😀.json');
    final report = ExclusiveFile(path);
    report.write(utf8.encode('héllo\r\n'));
    report.close();
    report.close();
    expect(File(path).readAsBytesSync(), utf8.encode('héllo\r\n'));
    expect(() => report.write([1]), throwsStateError);
  });
  test('existing files and directories are never replaced', () {
    final file = File(p.join(root.path, 'existing'))..writeAsStringSync('keep');
    for (final path in [file.path, root.path]) {
      expect(() => ExclusiveFile(path), throwsA(isA<FileSystemException>()));
    }
    expect(file.readAsStringSync(), 'keep');
  });
  test(
    'existing and dangling symlinks are never followed',
    () {
      final victim = File(p.join(root.path, 'victim'))
        ..writeAsStringSync('keep');
      final link = Link(p.join(root.path, 'report'))..createSync(victim.path);
      expect(
        () => ExclusiveFile(link.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(victim.readAsStringSync(), 'keep');
      link.updateSync(p.join(root.path, 'missing'));
      expect(
        () => ExclusiveFile(link.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(p.join(root.path, 'missing')).existsSync(), isFalse);
    },
    skip: Platform.isWindows ? 'POSIX symlinks' : false,
  );
  test(
    'replacement after open cannot redirect writes or close',
    () {
      final path = p.join(root.path, 'report');
      final original = p.join(root.path, 'original');
      final victim = File(p.join(root.path, 'victim'))
        ..writeAsStringSync('keep');
      final report = ExclusiveFile(path);
      try {
        File(path).renameSync(original);
        Link(path).createSync(victim.path);
        report.write(utf8.encode('report data'));
      } finally {
        report.close();
      }
      expect(victim.readAsStringSync(), 'keep');
      expect(File(original).readAsStringSync(), 'report data');
      expect(Link(path).existsSync(), isTrue);
    },
    skip: Platform.isWindows ? 'POSIX open-file rename and symlinks' : false,
  );
}
