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
  final directorySpellings = <String, String>{};
  for (final path in paths) {
    _checkDirectoryCase(path, directorySpellings);
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

/// Directories can contain outputs, but cannot be outputs of file entries.
void checkDirectoryCollisions(
  Iterable<String> files,
  Iterable<String> directories,
) {
  final fileNames = <String>{};
  final directorySpellings = <String, String>{};
  for (final file in files) {
    fileNames.add(file.toLowerCase());
    _checkDirectoryCase(file, directorySpellings);
  }
  final directoryNames = <String>{};
  for (final directory in directories) {
    relativePath(directory, output: true);
    _checkDirectoryCase(directory, directorySpellings, includeLeaf: true);
    final normalized = directory.toLowerCase();
    if (!directoryNames.add(normalized)) {
      throw StateError('Directory collision: $directory');
    }
    final parts = normalized.split('/');
    for (var i = 1; i <= parts.length; i++) {
      if (fileNames.contains(parts.take(i).join('/'))) {
        throw StateError('Output is both a file and a directory: $directory');
      }
    }
  }
}

// Register every parent, including implicit ones, with its original spelling.
// Sharing the same spelling is fine; aliasing it by case is host-dependent.
void _checkDirectoryCase(
  String path,
  Map<String, String> spellings, {
  bool includeLeaf = false,
}) {
  final parts = path.split('/');
  final count = parts.length - (includeLeaf ? 0 : 1);
  for (var i = 1; i <= count; i++) {
    final directory = parts.take(i).join('/');
    final key = directory.toLowerCase();
    final previous = spellings[key];
    if (previous != null && previous != directory) {
      throw StateError('Directory case collision: $previous and $directory');
    }
    spellings[key] = directory;
  }
}
