part of 'configurator.dart';

const statePath = '.whitelabel/state.json';

String digest(List<int> bytes) => sha256.convert(bytes).toString();

List<int>? readFile(String root, String relative) {
  final path = checkedPath(root, relative);
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return null;
  if (type != FileSystemEntityType.file) {
    throw FileSystemException('Expected a regular file', path);
  }
  return File(path).readAsBytesSync();
}

bool sameBytes(List<int>? a, List<int>? b) =>
    a == null || b == null ? a == b : digest(a) == digest(b);

class OwnedFile {
  OwnedFile(this.hash, this.platforms, this.brand, [this.mode]);
  final String hash;
  final int? mode;
  final Set<String> platforms;
  final String brand;

  bool selected(Set<String> selection) =>
      platforms.isEmpty || platforms.any(selection.contains);

  Map<String, Object?> toJson() => {
    'sha256': hash,
    if (mode != null) 'mode': mode,
    'platforms': platforms.toList()..sort(),
    'brand': brand,
  };
}

Map<String, OwnedFile> readInventory(List<int>? bytes) {
  if (bytes == null) return {};
  final state = stringMap(jsonDecode(utf8.decode(bytes)), 'state');
  checkKeys(state, {'schema_version', 'files'}, 'state');
  if (state['schema_version'] != 1 || state['schema_version'] is! int) {
    throw const FormatException('Unsupported ownership state version');
  }
  final files = stringMap(state['files'], 'state.files');
  final inventory = <String, OwnedFile>{};
  for (final entry in files.entries) {
    final path = relativePath(entry.key, output: true);
    final record = stringMap(entry.value, 'owned file');
    checkKeys(record, {'sha256', 'platforms', 'brand', 'mode'}, 'owned file');
    final hash = requiredString(record, 'sha256');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid ownership digest');
    }
    inventory[path] = OwnedFile(
      hash,
      readPlatforms(record['platforms'], present: true),
      requiredString(record, 'brand'),
      _readMode(record['mode']),
    );
  }
  checkCollisions(inventory.keys);
  return inventory;
}

int? _readMode(Object? value) {
  if (value == null) return null;
  if (value is! int || value < 0 || value > 0x1ff) {
    throw const FormatException('Invalid file permission mode');
  }
  return value;
}

/// One planned write. Null means the file is absent, not empty. Contents are
/// captured at planning time.
class FileChange {
  FileChange(
    this.path,
    List<int>? before,
    List<int>? after, {
    this.beforeMode,
    this.afterMode,
  }) : before = before == null ? null : List.unmodifiable(before),
       after = after == null ? null : List.unmodifiable(after) {
    _readMode(beforeMode);
    _readMode(afterMode);
  }

  final String path;
  final int? beforeMode;
  final int? afterMode;
  final List<int>? before;
  final List<int>? after;

  String get action => sameBytes(before, after) && beforeMode == afterMode
      ? 'unchanged'
      : after == null
      ? 'delete'
      : before == null
      ? 'create'
      : 'replace';

  Map<String, Object?> toJson() => {
    'path': path,
    'action': action,
    'before_sha256': before == null ? null : digest(before!),
    'after_sha256': after == null ? null : digest(after!),
    if (beforeMode != null) 'before_mode': beforeMode,
    if (afterMode != null) 'after_mode': afterMode,
  };
}

/// A rendered plan.
class ConfigurationPlan {
  ConfigurationPlan._(
    String projectRoot,
    List<FileChange> changes,
    this._stateChange,
  ) : projectRoot = canonicalDirectory(projectRoot),
      changes = List.unmodifiable(changes) {
    for (final change in changes) {
      relativePath(change.path, output: true);
    }
    checkCollisions(changes.map((change) => change.path));
    if (_stateChange.path != statePath) {
      throw const FormatException('Invalid ownership state destination');
    }
  }

  final String projectRoot;
  final List<FileChange> changes;
  final FileChange _stateChange;

  bool get hasChanges =>
      changes.any((change) => change.action != 'unchanged') ||
      _stateChange.action != 'unchanged';

  Map<String, Object?> toJson() => {
    'project': projectRoot,
    'files': changes.map((change) => change.toJson()).toList(),
    'ownership_changes': _stateChange.action != 'unchanged',
  };
}
