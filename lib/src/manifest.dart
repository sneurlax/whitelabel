import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'paths.dart';

const _manifestLimit = 1024 * 1024;

const supportedPlatforms = {
  'android',
  'ios',
  'linux',
  'macos',
  'web',
  'windows',
};
final variableName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// A parsed, immutable manifest. Application settings live in [variables];
/// validating them is the consumer's job.
class BrandManifest {
  BrandManifest._(
    this.brand,
    this.variables,
    this.platforms,
    this.files,
    this.sourceDirectory,
  );

  final String brand;
  final Map<String, Object?> variables;
  final Set<String> platforms;
  final List<ManifestFile> files;
  final String? sourceDirectory;

  /// Loads a regular UTF-8 manifest of at most 1 MiB. Symlinks to regular
  /// files are supported; streams and devices are not.
  static BrandManifest load(String path) {
    final file = File(path);
    // stat follows symlinks, preserving support for linked regular manifests.
    // POSIX character/block devices can otherwise be reported as type "file".
    final stat = file.statSync();
    if (stat.type != FileSystemEntityType.file ||
        !Platform.isWindows && stat.mode & 0xf000 != 0x8000) {
      throw FileSystemException('Expected a regular manifest file', path);
    }
    if (file.lengthSync() > _manifestLimit) {
      throw const FormatException('Manifest exceeds the 1 MiB text limit');
    }
    final reader = file.openSync();
    try {
      final bytes = BytesBuilder(copy: false);
      // The earlier stat is only a fast rejection. Bound the actual reads too,
      // including files that grow between the size check and opening/reading.
      while (bytes.length <= _manifestLimit) {
        final remaining = _manifestLimit + 1 - bytes.length;
        final chunk = reader.readSync(remaining < 65536 ? remaining : 65536);
        if (chunk.isEmpty) break;
        bytes.add(chunk);
      }
      if (bytes.length > _manifestLimit) {
        throw const FormatException('Manifest exceeds the 1 MiB text limit');
      }
      return parse(
        utf8.decode(bytes.takeBytes()),
        source: p.absolute(path),
        sourceDirectory: p.dirname(p.absolute(path)),
      );
    } finally {
      reader.closeSync();
    }
  }

  static BrandManifest parse(
    String text, {
    String? source,
    String? sourceDirectory,
  }) {
    if (text.length > _manifestLimit) {
      throw const FormatException('Manifest exceeds the 1 MiB text limit');
    }
    final document = loadYaml(
      text,
      sourceUrl: source == null ? null : Uri.file(source),
    );
    final map = stringMap(document, 'manifest');
    checkKeys(map, {
      'schema_version',
      'brand',
      'variables',
      'platforms',
      'files',
    }, 'manifest');
    if (map['schema_version'] != 1 || map['schema_version'] is! int) {
      throw const FormatException('schema_version must be the integer 1');
    }
    final brand = requiredString(map, 'brand');
    if (!RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(brand)) {
      throw const FormatException('brand must be a lowercase identifier');
    }
    final variables = map.containsKey('variables')
        ? stringMap(map['variables'], 'variables')
        : <String, Object?>{};
    for (final key in variables.keys) {
      if (!variableName.hasMatch(key) || key == 'brand') {
        throw FormatException('Invalid or reserved variable name: $key');
      }
    }
    final platforms = readPlatforms(
      map['platforms'],
      present: map.containsKey('platforms'),
    );
    final rawFiles = map['files'];
    if (rawFiles is! List) {
      throw const FormatException('files must be a list');
    }
    final files = <ManifestFile>[];
    for (final rawFile in rawFiles) {
      final file = stringMap(rawFile, 'file');
      checkKeys(file, {'source', 'destination', 'mode', 'platforms'}, 'file');
      final mode = file.containsKey('mode') ? file['mode'] : 'template';
      if (mode != 'template' && mode != 'copy') {
        throw const FormatException('file.mode must be template or copy');
      }
      final filePlatforms = readPlatforms(
        file['platforms'],
        present: file.containsKey('platforms'),
      );
      if (!platforms.containsAll(filePlatforms)) {
        throw const FormatException(
          'File platforms must be declared in manifest.platforms',
        );
      }
      files.add(
        ManifestFile._(
          relativePath(requiredString(file, 'source')),
          relativePath(requiredString(file, 'destination'), output: true),
          mode == 'template',
          filePlatforms,
        ),
      );
    }
    return BrandManifest._(
      brand,
      freezeValue(variables) as Map<String, Object?>,
      platforms,
      List.unmodifiable(files),
      sourceDirectory,
    );
  }
}

/// [source] is relative to the source root, [destination] to the project
/// root. Copies accept a file or a directory tree; templates are single UTF-8
/// files. An empty [platforms] set means the file is shared.
class ManifestFile {
  ManifestFile._(
    this.source,
    this.destination,
    this.isTemplate,
    this.platforms,
  );
  final String source;
  final String destination;
  final bool isTemplate;
  final Set<String> platforms;
}

Map<String, Object?> stringMap(Object? value, String label) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$label must be a map with string keys');
  }
  return Map<String, Object?>.from(value);
}

void checkKeys(Map<String, Object?> map, Set<String> allowed, String label) {
  final unknown = map.keys.where((key) => !allowed.contains(key));
  if (unknown.isNotEmpty) {
    throw FormatException('Unknown $label keys: ${unknown.join(', ')}');
  }
}

String requiredString(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

Set<String> readPlatforms(Object? value, {required bool present}) {
  if (!present) return const {};
  if (value is! List || value.any((item) => item is! String)) {
    throw const FormatException('platforms must be a list of strings');
  }
  final result = value.cast<String>().toSet();
  if (result.length != value.length ||
      !supportedPlatforms.containsAll(result)) {
    throw const FormatException('Unknown or duplicate platforms');
  }
  return Set.unmodifiable(result);
}

/// Deep-freezes JSON-compatible data, rejecting cycles and oversized trees.
Object? freezeValue(Object? value) =>
    _freezeValue(value, HashSet<Object>.identity(), _ValueBudget(), 0);

class _ValueBudget {
  int nodes = 0;
}

Object? _freezeValue(
  Object? value,
  Set<Object> seen,
  _ValueBudget budget,
  int depth,
) {
  if (++budget.nodes > 10000 || depth > 64) {
    throw const FormatException(
      'Variables exceed the nesting or expansion limit',
    );
  }
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is! List && value is! Map) {
    throw const FormatException('Variables must contain finite JSON values');
  }
  if (!seen.add(value)) {
    throw const FormatException('Recursive variables are not supported');
  }
  try {
    if (value is List) {
      return List<Object?>.unmodifiable(
        value.map((item) => _freezeValue(item, seen, budget, depth + 1)),
      );
    }
    final map = stringMap(value, 'variable');
    return Map<String, Object?>.unmodifiable(
      map.map(
        (key, item) =>
            MapEntry(key, _freezeValue(item, seen, budget, depth + 1)),
      ),
    );
  } finally {
    seen.remove(value);
  }
}
