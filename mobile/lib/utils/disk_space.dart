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

/// Bytes reserved for the phone itself, never offered to the cache.
const cacheFreeSpaceBufferBytes = 5 * 1024 * 1024 * 1024;

/// How big the cache could sustainably grow (MiB): current free space plus
/// whatever it already occupies (that space would become free again if the
/// cache were cleared), minus the reserved buffer. Never below 1 GiB. This is
/// the single source of truth behind both the settings slider's max range
/// AND [effectiveCacheBudgetMb] below — they used to compute this
/// independently and could drift apart.
int sustainableCacheMb({required int freeBytes, required int usedBytes}) {
  return ((freeBytes + usedBytes - cacheFreeSpaceBufferBytes) / (1024 * 1024)).floor().clamp(1024, 1 << 30);
}

/// The effective cache budget in MiB — the smaller of the CONFIGURED size
/// and [sustainableCacheMb]. Shared by the settings slider and the "Manage
/// phone cache" page so they always agree on "the budget": before this
/// existed, the settings slider clamped only its OWN on-screen value to the
/// sustainable ceiling while "Manage phone cache" showed the raw configured
/// value unclamped, so the two pages could show flatly different numbers for
/// the exact same setting (confirmed in the field: "17 GiB" on one screen,
/// "32 GiB" on the other, for one underlying setting).
/// [freeBytes] null (not yet fetched) passes the configured value through
/// unclamped rather than guessing.
int effectiveCacheBudgetMb({required int configuredMb, required int? freeBytes, required int usedBytes}) {
  if (freeBytes == null) {
    return configuredMb;
  }
  final sustainableMb = sustainableCacheMb(freeBytes: freeBytes, usedBytes: usedBytes);
  return configuredMb < sustainableMb ? configuredMb : sustainableMb;
}
