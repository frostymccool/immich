import 'package:flutter/services.dart';

/// Thin wrapper around the native Android foreground service that keeps this
/// app's PROCESS at foreground OOM-kill priority for the duration of a
/// copyparty import.
///
/// A plain WakelockPlus wakelock (build 93) plus the standard per-app
/// "Unrestricted" battery setting were confirmed NOT enough to stop Samsung
/// from silently killing a many-hour import — neither raises the process's
/// priority the way an active foreground service with a visible notification
/// does. This is the correct-layer fix: Android's own API for "this must keep
/// running", not another app-level workaround.
///
/// Start/stop calls are best-effort — a platform-channel failure here must
/// never break the upload itself; the wakelock and normal upload logic keep
/// working without the extra foreground promotion.
class CopypartyForegroundService {
  static const _channel = MethodChannel('immich/copyparty_foreground');

  static Future<void> start() async {
    try {
      await _channel.invokeMethod<void>('start');
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
