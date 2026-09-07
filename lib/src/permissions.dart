import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Only ordinary POSIX permission bits are copied, never setuid/setgid bits.
int? fileMode(String path) =>
    Platform.isWindows ? null : File(path).statSync().mode & 0x1ff;

void setFileMode(String path, int mode) {
  if (Platform.isWindows) return;
  if (mode < 0 || mode > 0x1ff) throw ArgumentError.value(mode, 'mode');
  final nativePath = path.toNativeUtf8();
  try {
    final library = DynamicLibrary.process();
    // Darwin's mode_t is 16 bits; other supported POSIX hosts use 32 bits.
    final result = Platform.isMacOS || Platform.isIOS
        ? library.lookupFunction<
            Int Function(Pointer<Utf8>, Uint16),
            int Function(Pointer<Utf8>, int)
          >('chmod')(nativePath, mode)
        : library.lookupFunction<
            Int Function(Pointer<Utf8>, Uint32),
            int Function(Pointer<Utf8>, int)
          >('chmod')(nativePath, mode);
    if (result != 0) {
      throw FileSystemException('Cannot set file permissions', path);
    }
  } finally {
    malloc.free(nativePath);
  }
}
