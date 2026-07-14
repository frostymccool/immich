import 'package:flutter/services.dart';

const _channel = MethodChannel('immich/disk_space');

/// Free space (bytes) on the app's internal storage partition — the same
/// partition the copyparty staging cache lives on. There's no cross-platform
/// Dart API for this; backed by a small native plugin (java.io.File.getFreeSpace()).
/// Returns null if the platform call fails for any reason.
Future<int?> freeSpaceBytes() async {
  try {
    final result = await _channel.invokeMethod<int>('freeSpaceBytes');
    return result;
  } catch (_) {
    return null;
  }
}
