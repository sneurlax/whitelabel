part of 'configurator.dart';

const statePath = '.whitelabel/state.json';
const transactionPath = '.whitelabel/transaction';

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

  /// A whole-file unified diff. Binary files are named, not dumped.
  String get diff {
    if (action == 'unchanged') return '';
    String mode(int? value) =>
        value == null ? 'default' : value.toRadixString(8).padLeft(4, '0');
    final permissionDiff = beforeMode == afterMode
        ? ''
        : 'File permissions $path: ${mode(beforeMode)} -> ${mode(afterMode)}\n';
    if (sameBytes(before, after)) return permissionDiff;
    String decode(List<int>? bytes) {
      final text = utf8.decode(bytes ?? []);
      if (text.contains('\x00')) throw const FormatException('Binary file');
      return text;
    }

    try {
      final oldText = decode(before);
      final newText = decode(after);
      List<String> lines(String text) {
        if (text.isEmpty) return [];
        final result = text.split('\n');
        if (text.endsWith('\n')) result.removeLast();
        return result;
      }

      String gitMode(int? mode) =>
          (mode ?? 0) & 0x49 == 0 ? '100644' : '100755';
      // Every textual entry needs a Git header: otherwise a following unified
      // diff can be parsed as part of an empty-file entry's extended metadata.
      final result = StringBuffer(permissionDiff)
        ..writeln(
          'diff --git ${jsonEncode('a/$path')} ${jsonEncode('b/$path')}',
        );
      if (before == null) {
        result.writeln('new file mode ${gitMode(afterMode)}');
      } else if (after == null) {
        result.writeln('deleted file mode ${gitMode(beforeMode)}');
      } else if (gitMode(beforeMode) != gitMode(afterMode)) {
        result
          ..writeln('old mode ${gitMode(beforeMode)}')
          ..writeln('new mode ${gitMode(afterMode)}');
      }
      if (oldText.isEmpty && newText.isEmpty) return result.toString();
      final oldLines = lines(oldText);
      final newLines = lines(newText);
      result
        ..writeln('--- ${before == null ? '/dev/null' : 'a/$path'}')
        ..writeln('+++ ${after == null ? '/dev/null' : 'b/$path'}')
        ..writeln(
          '@@ -${oldLines.isEmpty ? 0 : 1},${oldLines.length} '
          '+${newLines.isEmpty ? 0 : 1},${newLines.length} @@',
        );
      for (final (lines, prefix, text) in [
        (oldLines, '-', oldText),
        (newLines, '+', newText),
      ]) {
        for (final line in lines) {
          result.writeln('$prefix$line');
        }
        if (lines.isNotEmpty && !text.endsWith('\n')) {
          result.writeln(r'\ No newline at end of file');
        }
      }
      return result.toString();
    } on FormatException {
      return '${permissionDiff}Binary file $path: $action\n';
    }
  }
}

/// A copied directory. Existing directories are checked, never chmodded.
/// Directories remain after their owned files are pruned, like implicit parents.
class DirectoryChange {
  DirectoryChange._(this.path, this.existed, this.mode);

  final String path;
  final bool existed;
  final int? mode;

  String get action => existed ? 'unchanged' : 'create';
  Map<String, Object?> toJson() => {
    'path': path,
    'action': action,
    if (mode != null) 'mode': mode,
  };
  String get diff => existed
      ? ''
      : 'Create directory $path'
            '${mode == null ? '' : ' (mode ${mode!.toRadixString(8).padLeft(4, '0')})'}\n';
}

/// A rendered plan. Applying it fails if any file changed since planning.
class ConfigurationPlan {
  ConfigurationPlan._(
    String projectRoot,
    List<FileChange> changes,
    List<DirectoryChange> directories,
    this._stateChange,
  ) : projectRoot = canonicalDirectory(projectRoot),
      changes = List.unmodifiable(changes),
      directories = List.unmodifiable(directories) {
    for (final change in changes) {
      relativePath(change.path, output: true);
    }
    checkCollisions(changes.map((change) => change.path));
    checkDirectoryCollisions(
      changes.map((change) => change.path),
      directories.map((directory) => directory.path),
    );
    if (_stateChange.path != statePath) {
      throw const FormatException('Invalid ownership state destination');
    }
  }

  final String projectRoot;
  final List<FileChange> changes;
  final List<DirectoryChange> directories;
  final FileChange _stateChange;

  bool get hasChanges =>
      directories.any((directory) => !directory.existed) ||
      changes.any((change) => change.action != 'unchanged') ||
      _stateChange.action != 'unchanged';

  Map<String, Object?> toJson() => {
    'project': projectRoot,
    'files': changes.map((change) => change.toJson()).toList(),
    'directories': directories.map((directory) => directory.toJson()).toList(),
    'ownership_changes': _stateChange.action != 'unchanged',
  };

  /// Applies the plan under the project lock. [onWrite] runs after each write;
  /// if it throws, the transaction rolls back. If the process dies mid-apply,
  /// call [recoverConfiguration] before planning again. File locks coordinate
  /// processes, not isolates, so serialize calls within a process.
  void apply({void Function(FileChange change)? onWrite}) {
    withProjectLock(projectRoot, () {
      ensureNoTransaction(projectRoot);
      for (final change in [...changes, _stateChange]) {
        if (!sameBytes(readFile(projectRoot, change.path), change.before) ||
            change.beforeMode != null &&
                fileMode(checkedPath(projectRoot, change.path)) !=
                    change.beforeMode) {
          throw StateError('Plan is stale: ${change.path} changed; plan again');
        }
      }
      for (final directory in directories) {
        final path = checkedPath(projectRoot, directory.path);
        final type = FileSystemEntity.typeSync(path, followLinks: false);
        if (type !=
                (directory.existed
                    ? FileSystemEntityType.directory
                    : FileSystemEntityType.notFound) ||
            directory.existed &&
                directory.mode != null &&
                fileMode(path) != directory.mode) {
          throw StateError(
            'Plan is stale: directory ${directory.path} changed',
          );
        }
      }
      if (!hasChanges) return;
      final writes = [
        ...changes,
        _stateChange,
      ].where((change) => change.action != 'unchanged').toList();
      final directory = Directory(checkedPath(projectRoot, transactionPath))
        ..createSync();
      final createdDirectories = <String>{};
      try {
        // Protect files whose confidentiality comes from their original parent.
        setFileMode(directory.path, 0x1c0);
        for (final copied in directories.where((entry) => !entry.existed)) {
          var parent = copied.path;
          while (parent != '.') {
            if (!Directory(checkedPath(projectRoot, parent)).existsSync()) {
              createdDirectories.add(parent);
            }
            parent = p.posix.dirname(parent);
          }
        }
        for (var i = 0; i < writes.length; i++) {
          final change = writes[i];
          var parent = p.posix.dirname(change.path);
          while (parent != '.' && parent != '.whitelabel') {
            final path = checkedPath(projectRoot, parent);
            if (FileSystemEntity.typeSync(path, followLinks: false) ==
                FileSystemEntityType.notFound) {
              createdDirectories.add(parent);
            }
            parent = p.posix.dirname(parent);
          }
          if (change.before != null) {
            final backup = File(
              checkedPath(projectRoot, change.path),
            ).copySync(p.join(directory.path, '$i.old'));
            if (!sameBytes(backup.readAsBytesSync(), change.before)) {
              throw StateError('File changed while staging: ${change.path}');
            }
          }
          if (change.after != null) {
            // Copy the backup first so the replacement keeps the file's mode.
            final staged = change.before == null
                ? File(p.join(directory.path, '$i.new'))
                : File(
                    p.join(directory.path, '$i.old'),
                  ).copySync(p.join(directory.path, '$i.new'));
            if (change.afterMode != null) {
              // Create privately before writing bytes, including read-only copies.
              staged.createSync();
              setFileMode(staged.path, 0x180);
            }
            staged.writeAsBytesSync(change.after!, flush: true);
            if (change.afterMode != null) {
              setFileMode(staged.path, change.afterMode!);
            }
          }
        }
        // Nothing in the project is touched until the journal is durable.
        final journal = {
          'schema_version': 1,
          'changes': writes.map((change) => change.toJson()).toList(),
          'created_directories': createdDirectories.toList()..sort(),
        };
        File(
          p.join(directory.path, 'journal.tmp'),
        ).writeAsStringSync(jsonEncode(journal), flush: true);
        File(
          p.join(directory.path, 'journal.tmp'),
        ).renameSync(p.join(directory.path, 'journal.json'));
        // Create copied directories before installing any contents. Temporary
        // owner access permits installing into read-only source directories.
        for (final copied in directories.where((entry) => !entry.existed)) {
          final path = checkedPath(projectRoot, copied.path);
          Directory(path).createSync(recursive: true);
          if (copied.mode != null) setFileMode(path, copied.mode! | 0x1c0);
        }
        for (var i = 0; i < writes.length; i++) {
          final change = writes[i];
          final path = checkedPath(projectRoot, change.path);
          Directory(p.dirname(path)).createSync(recursive: true);
          if (change.after == null) {
            File(path).deleteSync();
          } else {
            _install(File(p.join(directory.path, '$i.new')), path);
          }
          onWrite?.call(change);
        }
        for (final copied in directories.reversed.where(
          (entry) => !entry.existed,
        )) {
          if (copied.mode != null) {
            setFileMode(checkedPath(projectRoot, copied.path), copied.mode!);
          }
        }
        // Deleting the journal is the commit point. Before it, recovery rolls
        // back; after it, only staging remains.
        File(p.join(directory.path, 'journal.json')).deleteSync();
      } catch (error) {
        try {
          _recover(projectRoot);
        } catch (recoveryError) {
          throw StateError(
            'Apply failed: $error. Recovery also failed: '
            '$recoveryError. Preserve .whitelabel and run recover.',
          );
        }
        rethrow;
      }
      _discardStaging(projectRoot);
    });
  }
}

void _install(File staged, String destination) {
  // Windows cannot rename over an existing file. The backup covers the gap
  // between delete and rename.
  if (File(destination).existsSync()) File(destination).deleteSync();
  staged.renameSync(destination);
}

/// Rolls back an apply interrupted before commit. Every backup is verified
/// first, and files edited after the interruption are left alone.
void recoverConfiguration(String projectRoot) {
  final root = canonicalDirectory(projectRoot);
  withProjectLock(root, () => _recover(root));
}

void ensureNoTransaction(String root) {
  final path = checkedPath(root, transactionPath);
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw StateError(
      'An unfinished transaction exists; run whitelabel recover',
    );
  }
}

void _recover(String root) {
  final path = checkedPath(root, transactionPath);
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.directory) {
    throw FileSystemException(
      'Transaction path is not a directory; remove it manually',
      path,
    );
  }
  // Also secure staging left by older versions before reading or restoring it.
  setFileMode(path, 0x1c0);
  final journalBytes = readFile(root, '$transactionPath/journal.json');
  if (journalBytes == null) {
    _discardStaging(root);
    return;
  }
  final journal = stringMap(jsonDecode(utf8.decode(journalBytes)), 'journal');
  checkKeys(journal, {
    'schema_version',
    'changes',
    'created_directories',
  }, 'journal');
  if (journal['schema_version'] != 1 ||
      journal['schema_version'] is! int ||
      journal['changes'] is! List ||
      journal['created_directories'] is! List) {
    throw const FormatException('Invalid transaction journal');
  }
  final restores = <FileChange>[];
  final changes = journal['changes'] as List;
  for (var i = 0; i < changes.length; i++) {
    final entry = stringMap(changes[i], 'journal entry');
    checkKeys(entry, {
      'path',
      'action',
      'before_sha256',
      'after_sha256',
      'before_mode',
      'after_mode',
    }, 'journal entry');
    final path = requiredString(entry, 'path');
    if (path != statePath) relativePath(path, output: true);
    final beforeHash = entry['before_sha256'];
    final afterHash = entry['after_sha256'];
    final beforeMode = _readMode(entry['before_mode']);
    final afterMode = _readMode(entry['after_mode']);
    for (final hash in [beforeHash, afterHash]) {
      if (hash != null &&
          (hash is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash))) {
        throw const FormatException('Invalid journal digest');
      }
    }
    final backup = beforeHash == null
        ? null
        : readFile(root, '$transactionPath/$i.old');
    if (beforeHash != null &&
        (backup == null ||
            digest(backup) != beforeHash ||
            beforeMode != null &&
                !Platform.isWindows &&
                fileMode(checkedPath(root, '$transactionPath/$i.old')) !=
                    beforeMode)) {
      throw StateError('Missing or corrupt backup for $path');
    }
    final current = readFile(root, path);
    final currentHash = current == null ? null : digest(current);
    if (currentHash != null &&
        currentHash != beforeHash &&
        currentHash != afterHash) {
      throw StateError(
        'File changed after interruption: $path; preserve it before recovery',
      );
    }
    if (current != null &&
        !Platform.isWindows &&
        (beforeMode != null || afterMode != null)) {
      final mode = fileMode(checkedPath(root, path));
      if (mode != beforeMode && mode != afterMode) {
        throw StateError('File permissions changed after interruption: $path');
      }
    }
    restores.add(FileChange(path, current, backup));
  }
  checkCollisions(restores.map((change) => change.path));
  final createdDirectories = (journal['created_directories'] as List).map((
    item,
  ) {
    if (item is! String) {
      throw const FormatException('Invalid journal directory');
    }
    relativePath(item, output: true);
    checkedPath(root, item);
    return item;
  }).toList()..sort((a, b) => b.length.compareTo(a.length));
  final directoryModes = <String, int>{};
  try {
    for (final relative in createdDirectories.reversed) {
      final path = checkedPath(root, relative);
      if (Directory(path).existsSync()) {
        final mode = fileMode(path);
        if (mode != null && mode & 0x1c0 != 0x1c0) {
          directoryModes[relative] = mode;
          setFileMode(path, mode | 0x1c0);
        }
      }
    }
    for (var i = restores.length - 1; i >= 0; i--) {
      final change = restores[i];
      final path = checkedPath(root, change.path);
      // No write is needed for entries that were never installed or were already
      // restored. This also avoids touching unchanged files in read-only parents.
      if (sameBytes(change.before, change.after) &&
          (change.after == null ||
              Platform.isWindows ||
              fileMode(path) ==
                  fileMode(checkedPath(root, '$transactionPath/$i.old')))) {
        continue;
      }
      if (change.after == null) {
        if (File(path).existsSync()) File(path).deleteSync();
      } else {
        Directory(p.dirname(path)).createSync(recursive: true);
        final temporary = File(
          checkedPath(root, '$transactionPath/restore.tmp'),
        );
        // A previous recovery may have stopped after copying a read-only backup.
        // Recreate this scratch file rather than truncating its old permissions.
        if (temporary.existsSync()) temporary.deleteSync();
        final staged = File(
          checkedPath(root, '$transactionPath/$i.old'),
        ).copySync(temporary.path);
        _install(staged, path);
      }
    }
    for (final relative in createdDirectories) {
      final directory = Directory(checkedPath(root, relative));
      if (directory.existsSync() &&
          directory.listSync(followLinks: false).isEmpty) {
        directory.deleteSync();
      }
    }
  } finally {
    // A directory containing unrelated files is retained with its old mode.
    for (final entry in directoryModes.entries.toList().reversed) {
      final path = checkedPath(root, entry.key);
      if (Directory(path).existsSync()) setFileMode(path, entry.value);
    }
  }
  // Validate before retiring the journal, so stray entries remain retryable.
  // Once rollback is complete, cleanup must not depend on surviving backups.
  final directory = Directory(checkedPath(root, transactionPath));
  _validateStaging(directory);
  File(
    checkedPath(root, '$transactionPath/journal.json'),
  ).renameSync(checkedPath(root, '$transactionPath/rollback-complete.json'));
  _discardStaging(root);
}

void _discardStaging(String root) {
  final directory = Directory(checkedPath(root, transactionPath));
  if (!directory.existsSync()) return;
  _validateStaging(directory);
  directory.deleteSync(recursive: true);
}

void _validateStaging(Directory directory) {
  // Delete through plain files only.
  for (final entity in directory.listSync(followLinks: false)) {
    if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('Unexpected transaction entry', entity.path);
    }
  }
}

final _activeLocks = <String>{};

void withProjectLock(String root, void Function() action) {
  if (!_activeLocks.add(root)) {
    throw StateError('Configuration is already active for $root');
  }
  try {
    _withFileLock(root, action);
  } finally {
    _activeLocks.remove(root);
  }
}

void _withFileLock(String root, void Function() action) {
  final stateDirectory = Directory(checkedPath(root, '.whitelabel'));
  stateDirectory.createSync();
  final lockPath = checkedPath(root, '.whitelabel/lock');
  final lockType = FileSystemEntity.typeSync(lockPath, followLinks: false);
  if (lockType != FileSystemEntityType.file &&
      lockType != FileSystemEntityType.notFound) {
    throw FileSystemException('Invalid project lock', lockPath);
  }
  final lock = File(lockPath).openSync(mode: FileMode.append);
  try {
    try {
      lock.lockSync(FileLock.exclusive);
    } on FileSystemException {
      throw StateError('Another whitelabel run holds the project lock');
    }
    try {
      action();
    } finally {
      lock.unlockSync();
    }
  } finally {
    lock.closeSync();
  }
}
