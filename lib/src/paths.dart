import 'dart:io';

import 'package:path/path.dart' as p;

/// Accepts only portable relative paths. Windows device names and 8.3 aliases
/// are rejected on every host so a manifest writes the same files everywhere.
String relativePath(String value, {bool output = false}) {
  final parts = value.split('/');
  if (value.isEmpty ||
      p.posix.isAbsolute(value) ||
      p.windows.isAbsolute(value) ||
      RegExp(r'[^\x20-\x7e]|~').hasMatch(value) ||
      RegExp(r'[\\:*?"<>|\x00-\x1f]').hasMatch(value) ||
      parts.any(
        (part) =>
            part.isEmpty ||
            part == '.' ||
            part == '..' ||
            part.endsWith('.') ||
            part.endsWith(' ') ||
            RegExp(
              r'^(con|conin\$|conout\$|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
              caseSensitive: false,
            ).hasMatch(part),
      )) {
    throw FormatException('Expected a portable relative path: "$value"');
  }
  if (output &&
      parts.any(
        (part) => const {
          '.git',
          '.dart_tool',
          '.whitelabel',
        }.contains(part.toLowerCase()),
      )) {
    throw FormatException('Reserved output path: "$value"');
  }
  return value;
}

String canonicalDirectory(String path) {
  final directory = Directory(p.absolute(path));
  if (!directory.existsSync()) {
    throw FileSystemException('Directory does not exist', directory.path);
  }
  return directory.resolveSymbolicLinksSync();
}

/// Joins [relative] onto [root], refusing any symlink along the way. The
/// caller has already canonicalized [root].
String checkedPath(String root, String relative) {
  if (FileSystemEntity.typeSync(root, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw FileSystemException('The selected root directory was replaced', root);
  }
  var current = root;
  final parts = relative.split('/');
  for (var i = 0; i < parts.length; i++) {
    current = p.join(current, parts[i]);
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw FileSystemException('Symbolic links are not permitted', current);
    }
    if (i != parts.length - 1 &&
        type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.notFound) {
      throw FileSystemException('Parent is not a directory', current);
    }
  }
  return current;
}

void checkCollisions(Iterable<String> paths) {
  final entries = <String>{};
  for (final path in paths) {
    final normalized = path.toLowerCase();
    if (!entries.add(normalized)) {
      throw StateError('Output collision: $path');
    }
  }
  for (final path in entries) {
    final parts = path.split('/');
    for (var i = 1; i < parts.length; i++) {
      if (entries.contains(parts.take(i).join('/'))) {
        throw StateError('Output is both a file and a directory: $path');
      }
    }
  }
}
