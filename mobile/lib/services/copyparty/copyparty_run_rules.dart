import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';

/// Small rules of the import run, kept out of the provider so each one has its own regression test.

/// How long a read of the card may go without any data before the check of an original gives up.
const sourceCheckStallTimeout = Duration(seconds: 60);

/// The SHA-512 (hex) of [data], for the check of an original before it is deleted.
///
/// Checks read the card one at a time, so a read that stops answering would hold every later check
/// ("Waiting to check the original" on every file). With no data for [stallTimeout] this throws a
/// [TimeoutException] instead, and the original is kept. [stopped] is polled per slice (Stop, Pause, or
/// Keep original) and throws [CopypartyCancelledException].
Future<String> sha512OfStream(
  Stream<List<int>> data, {
  Duration stallTimeout = sourceCheckStallTimeout,
  void Function(int bytesRead)? onProgress,
  bool Function()? stopped,
}) async {
  final sink = _DigestSink();
  final input = sha512.startChunkedConversion(sink);
  var read = 0;
  final guarded = data.timeout(
    stallTimeout,
    onTimeout: (out) => out.addError(TimeoutException('the memory card stopped answering while being read')),
  );
  await for (final chunk in guarded) {
    if (stopped?.call() ?? false) {
      throw const CopypartyCancelledException();
    }
    input.add(chunk);
    read += chunk.length;
    onProgress?.call(read);
  }
  input.close();
  return sink.value!.toString();
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// The files the upload loop may take next. While the user has paused the card copy (with the phone
/// cache on) only files already in the cache may go, so nothing is read from the card; with none left
/// the loop waits. Otherwise every pending file may go.
List<T> uploadableNow<T>(
  List<T> pending, {
  required bool cardPaused,
  required bool useCache,
  required bool Function(T) isCached,
}) => cardPaused && useCache ? pending.where(isCached).toList() : pending;

/// How a paused run is resumed: everything, only the card copy into the phone cache (nothing is sent), or only
/// the uploads of files already in the cache (nothing is read from the card).
enum ResumeMode { all, cacheOnly, uploadOnly }

/// The partial pauses a resume starts with. Without the phone cache there is no separate card copy, so every
/// mode resumes everything.
({bool cardPaused, bool uploadsPaused}) pausesForResume(ResumeMode mode, {required bool useCache}) => !useCache
    ? (cardPaused: false, uploadsPaused: false)
    : switch (mode) {
        ResumeMode.all => (cardPaused: false, uploadsPaused: false),
        ResumeMode.cacheOnly => (cardPaused: false, uploadsPaused: true),
        ResumeMode.uploadOnly => (cardPaused: true, uploadsPaused: false),
      };

/// What Stop does: a running upload is cancelled; a paused one (its loop already ended, nothing left to
/// cancel) goes straight to the summary as a stopped run.
enum StopAction { cancelRun, finishPaused, nothing }

StopAction stopActionFor({required bool running, required bool onProgressPage}) => running
    ? StopAction.cancelRun
    : onProgressPage
    ? StopAction.finishPaused
    : StopAction.nothing;

/// Camera RAW photo types.
const rawPhotoExtensions = {'dng', 'nef', 'nrw', 'orf', 'arw', 'cr2', 'cr3', 'rw2', 'raf', 'raw', 'pef', 'srw'};

/// Types the camera saves next to a RAW that make a good stack cover.
const stackCoverExtensions = {'jpg', 'jpeg', 'heic', 'heif'};

String _extOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// The Immich asset ids to stack for one capture (files with the same name in the same folder), cover first,
/// or null when there is nothing to stack yet: it needs a RAW and a JPG/HEIC, and every one of those must
/// already be in Immich, so the stack is made once, complete. Immich makes the first id the cover.
List<String>? rawJpgStack(List<({String filename, String? assetId})> files) {
  final covers = files.where((f) => stackCoverExtensions.contains(_extOf(f.filename))).toList()
    ..sort((a, b) => a.filename.compareTo(b.filename));
  final raws = files.where((f) => rawPhotoExtensions.contains(_extOf(f.filename))).toList()
    ..sort((a, b) => a.filename.compareTo(b.filename));
  if (covers.isEmpty || raws.isEmpty) {
    return null;
  }
  final all = [...covers, ...raws];
  if (all.any((f) => f.assetId == null)) {
    return null;
  }
  final ids = <String>[];
  for (final f in all) {
    if (!ids.contains(f.assetId)) {
      ids.add(f.assetId!);
    }
  }
  return ids.length < 2 ? null : ids;
}

/// Whether a file's original is deleted after a verified upload: the one-time choice made when it was added
/// to the import, else the "Delete after upload" setting.
bool shouldAutoDelete({required bool setting, bool? override}) => override ?? setting;

/// The card (storage volume) a path is on, so a delete problem on one card never affects another:
/// `/storage/EB55-F36E/DCIM/a.jpg` → `/storage/EB55-F36E`, `/storage/emulated/0/DCIM/a.jpg` →
/// `/storage/emulated/0`. Anything else: its folder.
String cardVolumeOf(String path) {
  final parts = path.split('/');
  // ['', 'storage', 'EB55-F36E', ...] or ['', 'storage', 'emulated', '0', ...] or ['', 'mnt', 'media_rw', 'X', ...]
  if (parts.length > 3 && parts[1] == 'storage') {
    if (parts[2] == 'emulated' && parts.length > 4) {
      return parts.sublist(0, 4).join('/');
    }
    return parts.sublist(0, 3).join('/');
  }
  if (parts.length > 4 && parts[1] == 'mnt' && parts[2] == 'media_rw') {
    return parts.sublist(0, 4).join('/');
  }
  final i = path.lastIndexOf('/');
  return i <= 0 ? '/' : path.substring(0, i);
}

/// The card's short name for messages (`/storage/EB55-F36E` → `EB55-F36E`).
String cardNameOf(String volume) => volume.split('/').where((p) => p.isNotEmpty).lastOrNull ?? volume;

/// Whether a delete failure means nothing on that card can be deleted (read-only card, no permission), so
/// the rest of the card's originals are kept without trying. A missing file or any other one-off failure
/// only affects that file.
bool blocksWholeCard(String reason) {
  final r = reason.toLowerCase();
  return r.contains('read-only file system') ||
      r.contains('erofs') ||
      r.contains('errno = 30') ||
      r.contains('no folder permission') ||
      r.contains('permission denied') ||
      r.contains('eacces') ||
      r.contains('errno = 13') ||
      r.contains('operation not permitted');
}

/// Why a copy into the phone cache failed.
enum CacheFailure { phoneFull, cardUnreadable, other }

CacheFailure cacheFailureOf(Object error) {
  final r = '$error'.toLowerCase();
  if (r.contains('no space') || r.contains('enospc') || r.contains('errno = 28') || r.contains('disk full')) {
    return CacheFailure.phoneFull;
  }
  if (r.contains('no such file') || r.contains('enoent') || r.contains('errno = 2,') || r.contains('i/o error')) {
    return CacheFailure.cardUnreadable;
  }
  return CacheFailure.other;
}

/// The warning above the progress list for files that could not be copied into the phone cache, by cause.
/// Empty when there are none.
List<String> cacheFailureWarnings(Map<CacheFailure, int> counts) {
  String n(int c) => '$c file${c == 1 ? '' : 's'}';
  String verb(int c) => c == 1 ? 'is' : 'are';
  final full = counts[CacheFailure.phoneFull] ?? 0;
  final card = counts[CacheFailure.cardUnreadable] ?? 0;
  final other = counts[CacheFailure.other] ?? 0;
  final fullText =
      '${n(full)} could not be cached (phone storage full) and ${verb(full)} reading straight from the card. '
      'Keep it connected until they finish.';
  final cardText =
      '${n(card)} could not be read from the card (removed or changed?). Re-insert the card and tap Retry on them.';
  final otherText =
      '${n(other)} could not be copied to the phone cache and ${verb(other)} reading straight from the card. '
      'Save log shows why.';
  return [if (full > 0) fullText, if (card > 0) cardText, if (other > 0) otherText];
}
