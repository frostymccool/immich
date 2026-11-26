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
