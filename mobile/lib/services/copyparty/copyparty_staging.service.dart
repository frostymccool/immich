import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/services/copyparty/copyparty_logger.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';

/// One staged copy in the phone cache — either complete (marker-verified,
/// `complete: true`, safe to Upload) or an orphaned partial with no marker
/// (`complete: false`, Delete-only — there's no record of its source path or
/// upload state to safely resume from here).
typedef StagedCacheEntry = ({
  String sourcePath,
  String filename,
  int sizeBytes,
  String stagedPath,
  DateTime modified,
  bool complete,
});

/// Local staging for copyparty imports (batch: item 4).
///
/// Copies each source file (typically on a slow/removable USB volume) to local
/// phone storage BEFORE hashing/uploading, so:
///   * the slow source is read exactly once (the copy also computes the up2k
///     hashes in the same pass),
///   * an upload can finish even if the card is pulled mid-transfer,
///   * an interrupted upload resumes from the local copy with no re-read.
///
/// Corruption safety is anchored on a completion MARKER sidecar that is written
/// (atomically, temp→rename) ONLY after a fully-copied, length-verified local
/// copy. The marker's presence therefore proves the staged copy is complete and
/// records everything needed to upload it (chunk hashes, file hash, sizes). On
/// resume we trust a marker whose recorded source size + mtime still match the
/// current source — no re-hash needed (the marker can't exist for a partial copy).
class CopypartyStagingService {
  final CopypartyUploaderService _uploader;
  final CopypartyLogger? _log;
  final Future<Directory> Function() _stagingDirProvider;

  CopypartyStagingService(this._uploader, {CopypartyLogger? logger, required this._stagingDirProvider}) : _log = logger;

  static const int _markerVersion = 1;

  Directory? _cachedDir;

  Future<Directory> _dir() async {
    final cached = _cachedDir;
    if (cached != null) {
      return cached;
    }
    final dir = await _stagingDirProvider();
    await dir.create(recursive: true);
    _cachedDir = dir;
    return dir;
  }

  /// Deterministic, collision-resistant staged base name for a source path.
  String _baseFor(String sourcePath) {
    final digest = sha1.convert(utf8.encode(sourcePath));
    final ext = sourcePath.contains('.') ? sourcePath.split('.').last : 'bin';
    // Keep the extension so tools inspecting the staging dir can tell file types.
    return '$digest.$ext';
  }

  Future<({File staged, File marker})> _pathsFor(String sourcePath) async {
    final dir = await _dir();
    final base = _baseFor(sourcePath);
    return (staged: File('${dir.path}/$base'), marker: File('${dir.path}/$base.stagemeta'));
  }

  /// Bytes already sitting in the local staging cache for [sourcePath] —
  /// partial or complete, marker or no marker — or 0 if nothing is cached
  /// yet. Deliberately lighter than [findValidStaged]: the import picker uses
  /// this to show "already cached on phone" for files not yet selected for
  /// upload, before any marker validation (or even a copy) has happened.
  Future<int> stagedBytesFor(String sourcePath) async {
    try {
      final paths = await _pathsFor(sourcePath);
      if (paths.staged.existsSync()) {
        return await paths.staged.length();
      }
    } catch (_) {}
    return 0;
  }

  /// Returns a ready-to-upload [HashedFile] pointing at an EXISTING valid staged
  /// copy for [sourcePath], or null if none exists / it no longer matches the
  /// source (in which case any stale staged files are removed).
  Future<HashedFile?> findValidStaged(String sourcePath) async {
    final paths = await _pathsFor(sourcePath);
    if (!paths.marker.existsSync() || !paths.staged.existsSync()) {
      return null;
    }
    try {
      final meta = jsonDecode(await paths.marker.readAsString()) as Map<String, dynamic>;
      if (meta['v'] != _markerVersion || meta['sourcePath'] != sourcePath) {
        await _deletePaths(paths);
        return null;
      }
      final sourceSize = meta['sourceSize'] as int;
      final stagedLen = await paths.staged.length();

      // The staged copy must be internally complete per its OWN marker. The
      // marker is written atomically only after a length-verified copy, so a
      // present marker + matching staged length proves a complete copy. A
      // mismatch here means the staged file is corrupt/incomplete → discard.
      if (meta['stagedSize'] != stagedLen || stagedLen != sourceSize) {
        _log?.log('staging: incomplete/corrupt staged copy for ${sourcePath.split('/').last} — discarding');
        await _deletePaths(paths);
        return null;
      }

      final source = File(sourcePath);
      if (source.existsSync()) {
        // Source still here: it must be UNCHANGED since we staged it, or the
        // staged copy is stale (source edited) → re-stage.
        final srcStat = source.statSync();
        final sourceUnchanged =
            sourceSize == srcStat.size && meta['sourceMtimeMs'] == srcStat.modified.millisecondsSinceEpoch;
        if (!sourceUnchanged) {
          _log?.log('staging: stale copy for ${sourcePath.split('/').last} (source changed) — discarding');
          await _deletePaths(paths);
          return null;
        }
      } else {
        // Source GONE (card pulled) — this is the case the feature exists for.
        // We can't cross-check against the source, but the atomic marker proves
        // the staged copy was complete when written, so trust it and let the
        // upload finish. NEVER delete it here. (data-integrity finding 1)
        _log?.log('staging: source gone for ${sourcePath.split('/').last} — finishing from complete local copy');
      }

      final chunkHashes = (meta['chunkHashes'] as List<dynamic>).cast<String>();
      _log?.log('staging: reusing valid local copy for ${sourcePath.split('/').last} (no re-read)');
      return HashedFile(
        path: paths.staged.path,
        filename: meta['filename'] as String,
        totalBytes: sourceSize,
        chunkSizeBytes: meta['chunkSize'] as int,
        chunkHashes: chunkHashes,
        fileHash: meta['fileHash'] as String,
        lastModifiedMs: meta['lastModifiedMs'] as int,
      );
    } catch (e) {
      _log?.log('staging: unreadable marker for ${sourcePath.split('/').last} ($e) — discarding');
      await _deletePaths(paths);
      return null;
    }
  }

  /// Copies [sourcePath] to local storage (computing hashes in the same pass)
  /// and writes the completion marker atomically. Returns a [HashedFile] whose
  /// `path` is the local staged copy. Throws on any IO failure (e.g. out of
  /// space) — the caller should fall back to uploading directly from the source.
  Future<HashedFile> stage(
    String sourcePath, {
    void Function(int bytesProcessed, int totalBytes, bool verifying)? onProgress,
    Completer<void>? cancelToken,
  }) async {
    final paths = await _pathsFor(sourcePath);
    // Clear a stale/incomplete MARKER only — findValidStaged() already ruled
    // out a valid complete pair before this was ever called, but a marker
    // shouldn't exist without one anyway (defensive). Deliberately do NOT
    // delete the staged file itself: a partial from a previous paused/skipped
    // attempt is exactly what stageAndHash() now resumes from instead of
    // re-reading the whole (slow) USB source again. (pause/resume fix)
    for (final f in [paths.marker, File('${paths.marker.path}.tmp')]) {
      try {
        if (f.existsSync()) {
          await f.delete();
        }
      } catch (_) {}
    }

    final hashed = await _uploader.stageAndHash(
      sourcePath,
      paths.staged.path,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );

    final srcStat = File(sourcePath).statSync();
    final marker = {
      'v': _markerVersion,
      'sourcePath': sourcePath,
      'sourceSize': hashed.totalBytes,
      'sourceMtimeMs': srcStat.modified.millisecondsSinceEpoch,
      'stagedSize': hashed.totalBytes,
      'filename': hashed.filename,
      'chunkSize': hashed.chunkSizeBytes,
      'fileHash': hashed.fileHash,
      'chunkHashes': hashed.chunkHashes,
      'lastModifiedMs': hashed.lastModifiedMs,
    };
    // Atomic marker write: temp then rename, so a crash mid-write can never
    // leave a truncated marker that would be trusted on resume.
    final tmp = File('${paths.marker.path}.tmp');
    await tmp.writeAsString(jsonEncode(marker), flush: true);
    await tmp.rename(paths.marker.path);
    return hashed;
  }

  /// Everything currently in the cache: complete (marker-verified) copies,
  /// PLUS any orphaned partial with no marker (an abandoned or still-copying
  /// attempt). Orphans have no recorded source path, so `sourcePath` is set to
  /// the staged path itself and they can only be deleted, not uploaded — but
  /// they are still real disk usage, and previously being excluded here made
  /// this page's total silently disagree with the cache-size indicator
  /// elsewhere, with no way for the user to see or reclaim that space.
  /// (cache-consistency fix)
  Future<List<StagedCacheEntry>> listEntries() async {
    final entries = <StagedCacheEntry>[];
    final markedStagedPaths = <String>{};
    try {
      final dir = await _dir();
      if (!dir.existsSync()) {
        return entries;
      }
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.stagemeta')) {
          continue;
        }
        try {
          final meta = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
          if (meta['v'] != _markerVersion) {
            continue;
          }
          final stagedPath = entity.path.substring(0, entity.path.length - '.stagemeta'.length);
          if (!File(stagedPath).existsSync()) {
            continue;
          }
          markedStagedPaths.add(stagedPath);
          final stat = entity.statSync();
          entries.add((
            sourcePath: meta['sourcePath'] as String,
            filename: meta['filename'] as String,
            sizeBytes: meta['sourceSize'] as int,
            stagedPath: stagedPath,
            modified: stat.modified,
            complete: true,
          ));
        } catch (_) {}
      }
      await for (final entity in dir.list()) {
        if (entity is! File) {
          continue;
        }
        final path = entity.path;
        if (path.endsWith('.stagemeta') || path.endsWith('.stagemeta.tmp') || markedStagedPaths.contains(path)) {
          continue;
        }
        try {
          final stat = entity.statSync();
          entries.add((
            sourcePath: path,
            filename: '${path.split('/').last} (incomplete copy)',
            sizeBytes: await entity.length(),
            stagedPath: path,
            modified: stat.modified,
            complete: false,
          ));
        } catch (_) {}
      }
    } catch (_) {}
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  }

  /// Total bytes the cache currently holds — the sum of staged copy sizes
  /// (markers/temp files excluded). Used to bound read-ahead to the configured
  /// cache budget. (cache-size feature)
  Future<int> currentCacheBytes() async {
    try {
      final dir = await _dir();
      if (!dir.existsSync()) {
        return 0;
      }
      int total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) {
          continue;
        }
        final path = entity.path;
        if (path.endsWith('.stagemeta') || path.endsWith('.stagemeta.tmp')) {
          continue;
        }
        try {
          total += await entity.length();
        } catch (_) {}
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Deletes the staged copy + marker for a source path (after it is fully
  /// confirmed on all backends, or when discarding a stale copy).
  Future<void> discard(String sourcePath) async {
    await _deletePaths(await _pathsFor(sourcePath));
  }

  /// Deletes an orphaned partial (no marker, so no known source path) by its
  /// staged path directly — used for the incomplete entries `listEntries()`
  /// surfaces so the user can reclaim that space even though it can't be
  /// resumed/uploaded from here.
  Future<void> discardOrphan(String stagedPath) async {
    try {
      final f = File(stagedPath);
      if (f.existsSync()) {
        await f.delete();
      }
    } catch (_) {}
  }

  Future<void> _deletePaths(({File staged, File marker}) paths) async {
    for (final f in [paths.staged, paths.marker, File('${paths.marker.path}.tmp')]) {
      try {
        if (f.existsSync()) {
          await f.delete();
        }
      } catch (_) {}
    }
  }

  /// Removes staged files whose marker is older than [maxAge] — a backstop
  /// against leftovers from an app that was killed mid-import and never resumed.
  /// Recent staged files (within [maxAge]) are kept so a near-term resume can
  /// still reuse them.
  Future<void> sweepStale(Duration maxAge, DateTime now) async {
    try {
      final dir = await _dir();
      if (!dir.existsSync()) {
        return;
      }
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.stagemeta')) {
          continue;
        }
        try {
          final stat = entity.statSync();
          if (now.difference(stat.modified) <= maxAge) {
            continue;
          }
          final base = entity.path.substring(0, entity.path.length - '.stagemeta'.length);
          await _deletePaths((staged: File(base), marker: entity));
          _log?.log('staging: swept stale ${entity.path.split('/').last}');
        } catch (_) {}
      }
    } catch (_) {}
  }
}
