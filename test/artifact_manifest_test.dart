import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/artifact_manifest.dart';
import 'support/process.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('artifact-manifest-'));
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'inventories match across roots and detect changed and missing files',
    () {
      final a = Directory(p.join(root.path, 'a'))..createSync();
      final b = Directory(p.join(root.path, 'longer-b'))..createSync();
      File(p.join(a.path, 'binary')).writeAsBytesSync([0, 255, 17]);
      File(p.join(b.path, 'binary')).writeAsBytesSync([0, 255, 17]);
      expect(
        artifactDifferences(artifactManifest(a.path), artifactManifest(b.path)),
        isEmpty,
      );
      File(p.join(b.path, 'binary')).writeAsBytesSync([0, 255, 18]);
      File(p.join(b.path, 'extra')).writeAsStringSync('extra');
      expect(
        artifactDifferences(artifactManifest(a.path), artifactManifest(b.path)),
        ['binary', 'extra'],
      );
    },
  );

  test(
    'special artifact files are rejected without blocking',
    () async {
      final artifact = Directory(p.join(root.path, 'artifact'))..createSync();
      expect(
        Process.runSync('mkfifo', [p.join(artifact.path, 'pipe')]).exitCode,
        0,
      );
      final script = File(p.join(root.path, 'inventory.dart'))
        ..writeAsStringSync("""
import '${Uri.file(p.absolute('tool/artifact_manifest.dart'))}';
void main(List<String> args) { artifactManifest(args.single); }
""");
      final result = await runDart(script, [artifact.path]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Unsupported artifact entry'));
    },
    skip: Platform.isWindows ? 'POSIX named pipes' : false,
  );

  test('empty artifacts cannot produce a false matching result', () {
    expect(() => artifactManifest(root.path), throwsStateError);
  });

  test('empty directories are part of the manifest', () {
    final a = Directory(p.join(root.path, 'a'))..createSync();
    final b = Directory(p.join(root.path, 'b'))..createSync();
    File(p.join(a.path, 'file')).writeAsStringSync('x');
    File(p.join(b.path, 'file')).writeAsStringSync('x');
    Directory(p.join(b.path, 'empty')).createSync();
    expect(
      artifactDifferences(artifactManifest(a.path), artifactManifest(b.path)),
      ['empty'],
    );
  });

  test(
    'symlink targets are recorded without following them',
    () {
      final outside = File(p.join(root.path, 'outside'))
        ..writeAsStringSync('data');
      final artifact = Directory(p.join(root.path, 'artifact'))..createSync();
      final link = Link(p.join(artifact.path, 'link'))
        ..createSync(outside.path);
      final first = artifactManifest(artifact.path);
      outside.writeAsStringSync('changed outside the artifact');
      expect(
        artifactDifferences(first, artifactManifest(artifact.path)),
        isEmpty,
      );
      link.updateSync('different-target');
      expect(artifactDifferences(first, artifactManifest(artifact.path)), [
        'link',
      ]);
    },
    skip: Platform.isWindows ? 'POSIX symlinks' : false,
  );

  test(
    'executable permission changes are artifact differences',
    () {
      final file = File(p.join(root.path, 'binary'))
        ..writeAsStringSync('binary');
      expect(Process.runSync('chmod', ['644', file.path]).exitCode, 0);
      final first = artifactManifest(root.path);
      expect(Process.runSync('chmod', ['755', file.path]).exitCode, 0);
      expect(artifactDifferences(first, artifactManifest(root.path)), [
        'binary',
      ]);
    },
    skip: Platform.isWindows ? 'POSIX executable bits' : false,
  );
}
