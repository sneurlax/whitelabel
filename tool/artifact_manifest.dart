import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Content, executable-bit, and directory inventory. Timestamps and absolute
/// root names are not artifact content; symlink targets are compared without
/// being followed and signatures are not normalized.
Map<String, String> artifactManifest(String root) {
  final result = <String, String>{};
  final entities = Directory(root).listSync(recursive: true, followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in entities) {
    final relative = p.relative(entity.path, from: root).replaceAll('\\', '/');
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      result[relative] = 'link:${Link(entity.path).targetSync()}';
    } else if (type == FileSystemEntityType.file) {
      final executable = Platform.isWindows ? 0 : entity.statSync().mode & 0x49;
      result[relative] =
          'file:$executable:${sha256.convert(File(entity.path).readAsBytesSync())}';
    } else if (type == FileSystemEntityType.directory) {
      result[relative] = 'dir:';
    } else {
      throw FileSystemException('Unsupported artifact entry', entity.path);
    }
  }
  if (result.isEmpty) throw StateError('No artifact files found in $root');
  return result;
}

List<String> artifactDifferences(
  Map<String, String> first,
  Map<String, String> second,
) => (first.keys.toSet().union(second.keys.toSet()).toList()..sort())
    .where((path) => first[path] != second[path])
    .toList();
