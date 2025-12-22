// This file is used by the flutter rust bridge to find the correct library location.

import 'dart:ffi';
import 'dart:io';

/// Loads the native library for the current platform.
DynamicLibrary loadNativeLibrary() {
  if (Platform.isLinux) {
    return DynamicLibrary.open('libcheddarproxy_core.so');
  } else if (Platform.isMacOS) {
    return DynamicLibrary.open('libcheddarproxy_core.dylib');
  } else if (Platform.isWindows) {
    return DynamicLibrary.open('cheddarproxy_core.dll');
  }
  throw UnsupportedError('Unsupported platform');
}
