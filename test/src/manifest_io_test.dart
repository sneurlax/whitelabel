import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:whitelabel/whitelabel.dart';

import '../support/process.dart';

const _limit = 1024 * 1024;
const _manifest = 'schema_version: 1\nbrand: demo\nfiles: []\n';

void main() {
  late Directory root;
  late File file;
  setUp(() {
    root = Directory.systemTemp.createTempSync('manifest-io-');
    file = File(p.join(root.path, 'brand.yaml'));
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('accepts exactly the byte limit, including UTF-8 comments', () {
    final prefix = '$_manifest#é';
    file.writeAsStringSync(
      prefix + 'x' * (_limit - utf8.encode(prefix).length),
    );
    expect(file.lengthSync(), _limit);
    expect(BrandManifest.load(file.path).brand, 'demo');
  });
  for (final contents in [
    _manifest,
    'x' * (_limit + 5000),
    '\xff',
    'bad: [}',
  ]) {
    test(
      'bounds reads and closes the handle with stale size (${contents.length})',
      () {
        file.writeAsBytesSync(
          contents == '\xff' ? [255] : utf8.encode(contents),
        );
        final empty = File(p.join(root.path, 'empty'))..writeAsStringSync('');
        final tracked = _GrowingFile(file, empty.statSync());
        void load() => IOOverrides.runZoned(
          () => BrandManifest.load(file.path),
          createFile: (_) => tracked,
        );
        if (contents == _manifest) {
          load();
          expect(tracked.bytesRead, utf8.encode(contents).length);
        } else {
          expect(load, throwsFormatException);
          final length = contents == '\xff' ? 1 : utf8.encode(contents).length;
          expect(tracked.bytesRead, length > _limit ? _limit + 1 : length);
        }
        expect(tracked.closed, isTrue);
      },
    );
  }
  test(
    'still accepts symlinks to regular manifests',
    () {
      file.writeAsStringSync(_manifest);
      final link = Link(p.join(root.path, 'linked.yaml'))
        ..createSync(file.path);
      expect(BrandManifest.load(link.path).brand, 'demo');
    },
    skip: Platform.isWindows ? 'POSIX symlinks' : false,
  );
  test('accepts a UTF-8 BOM', () {
    file.writeAsBytesSync([0xef, 0xbb, 0xbf, ...utf8.encode(_manifest)]);
    expect(BrandManifest.load(file.path).brand, 'demo');
  });
  test(
    'rejects a device stat before any read',
    () {
      file.writeAsStringSync(_manifest);
      final tracked = _GrowingFile(file, File('/dev/zero').statSync());
      expect(
        () => IOOverrides.runZoned(
          () => BrandManifest.load(file.path),
          createFile: (_) => tracked,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(tracked.bytesRead, 0);
    },
    skip: Platform.isWindows ? 'POSIX device modes' : false,
  );
  test('rejects directories as manifests', () {
    expect(
      () => BrandManifest.load(root.path),
      throwsA(isA<FileSystemException>()),
    );
  });
  test(
    'rejects a FIFO without waiting for a writer',
    () async {
      expect(Process.runSync('mkfifo', [file.path]).exitCode, 0);
      final script = File(p.join(root.path, 'load.dart'))
        ..writeAsStringSync('''
import 'package:whitelabel/whitelabel.dart';
void main(List<String> args) { BrandManifest.load(args.single); }
''');
      final result = await runDart(script, [file.path]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Expected a regular manifest file'));
    },
    skip: Platform.isWindows ? 'POSIX named pipes' : false,
  );
}

// Simulate a file growing between stat and open without a timing-dependent race.
class _GrowingFile implements File {
  _GrowingFile(this.file, this.initialStat);
  final File file;
  final FileStat initialStat;
  int bytesRead = 0;
  bool closed = false;
  @override
  FileStat statSync() => initialStat;
  @override
  int lengthSync() => 0;
  @override
  Directory get parent => file.parent;
  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      _TrackedReader(file.openSync(mode: mode), this);
  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    final bytes = file.readAsBytesSync();
    bytesRead += bytes.length;
    return encoding.decode(bytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TrackedReader implements RandomAccessFile {
  _TrackedReader(this.file, this.owner);
  final RandomAccessFile file;
  final _GrowingFile owner;
  @override
  Uint8List readSync(int bytes) {
    final result = file.readSync(bytes);
    owner.bytesRead += result.length;
    return result;
  }

  @override
  void closeSync() {
    file.closeSync();
    owner.closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
