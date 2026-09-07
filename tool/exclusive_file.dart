import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// A report stream created without replacing any existing directory entry.
/// Writes and close operate on this handle, never on a reopened pathname.
/// On write failure a partial file may remain; deleting by name would race
/// with another process replacing that entry.
class ExclusiveFile {
  ExclusiveFile(this.path) {
    if (path.contains('\x00')) throw ArgumentError('Report path contains NUL');
    _stream = using((arena) {
      if (Platform.isWindows) {
        final open = _library
            .lookupFunction<
              Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>),
              Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>)
            >('_wfopen');
        return open(
          path.toNativeUtf16(allocator: arena),
          'wbx'.toNativeUtf16(allocator: arena),
        );
      }
      final open = _library
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>),
            Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>)
          >('fopen');
      return open(
        path.toNativeUtf8(allocator: arena),
        'wbx'.toNativeUtf8(allocator: arena),
      );
    });
    if (_stream == nullptr) {
      throw FileSystemException('Cannot create report exclusively', path);
    }
  }

  static final _library = Platform.isWindows
      ? DynamicLibrary.open('ucrtbase.dll')
      : DynamicLibrary.process();
  static final _write = _library
      .lookupFunction<
        Size Function(Pointer<Void>, Size, Size, Pointer<Void>),
        int Function(Pointer<Void>, int, int, Pointer<Void>)
      >('fwrite');
  static final _close = _library
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'fclose',
      );

  final String path;
  late Pointer<Void> _stream;

  void write(List<int> bytes) {
    if (_stream == nullptr) throw StateError('Report is closed');
    if (bytes.isEmpty) return;
    using((arena) {
      final buffer = arena<Uint8>(bytes.length);
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      if (_write(buffer.cast(), 1, bytes.length, _stream) != bytes.length) {
        throw FileSystemException(
          'Cannot write report; partial file retained',
          path,
        );
      }
    });
  }

  void close() {
    if (_stream == nullptr) return;
    final stream = _stream;
    _stream = nullptr;
    if (_close(stream) != 0) {
      throw FileSystemException(
        'Cannot flush report; partial file retained',
        path,
      );
    }
  }
}
