import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:openapi/api.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/copyparty_receipt.repository.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/copyparty/copyparty_file_pairer.dart';
import 'package:immich_mobile/services/copyparty/copyparty_foreground_service.dart';
import 'package:immich_mobile/services/copyparty/copyparty_logger.dart';
import 'package:immich_mobile/services/copyparty/copyparty_staging.service.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _copypartyPasswordKey = 'copyparty_password';

/// Returns the Immich asset id if a file with this content already exists in
/// Immich (matched by CHECKSUM, decision B), or null if not present. Returns
/// the sentinel 'present' when Immich confirms a duplicate but gives no id.
/// Throws on network/API failure so callers can show an error state.
Future<String?> immichAssetIdByChecksum(AssetsApi api, String localPath) async {
  // Immich identifies content by SHA-1 (base64). STREAM the hash — these are
  // memory-card videos that can be multiple GB; readAsBytes would OOM.
  final sink = _DigestSink();
  final input = sha1.startChunkedConversion(sink);
  await for (final chunk in File(localPath).openRead()) {
    input.add(chunk);
  }
  input.close();
  final sha1b64 = base64.encode(sink.value!.bytes);

  final resp = await api.checkBulkUpload(
    AssetBulkUploadCheckDto(
      assets: [AssetBulkUploadCheckItem(checksum: sha1b64, id: localPath)],
    ),
  );
  if (resp == null || resp.results.isEmpty) {
    return null;
  }
  final r = resp.results.first;
  // 'reject' means the content is already in Immich (duplicate). Treat ANY
  // reject as present even if the server omits/nulls the asset id.
  if (r.action == AssetUploadAction.reject) {
    return r.assetId.isPresent ? (r.assetId.value ?? 'present') : 'present';
  }
  return null;
}

/// Captures the final Digest from a chunked hash conversion.
class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

// ---------------------------------------------------------------------------
// Service providers
// ---------------------------------------------------------------------------

/// Shared diagnostic logger — single instance so the settings screen can read
/// the same file the uploader writes to.
final copypartyLoggerProvider = Provider<CopypartyLogger>((ref) => CopypartyLogger.instance);

final copypartyUploaderProvider = Provider<CopypartyUploaderService>((ref) {
  final allowSelfSigned = ref.watch(appConfigProvider.select((c) => c.copyparty.allowSelfSignedCert));
  http.Client client;
  if (allowSelfSigned) {
    final httpClient = HttpClient()..badCertificateCallback = (cert, host, port) => true;
    client = IOClient(httpClient);
  } else {
    client = http.Client();
  }
  final service = CopypartyUploaderService(client: client, logger: ref.watch(copypartyLoggerProvider));
  ref.onDispose(service.dispose);
  return service;
});

final copypartyReceiptRepositoryProvider = Provider<CopypartyReceiptRepository>(
  (ref) => CopypartyReceiptRepository(ref.watch(driftProvider)),
);

/// Local-staging service (batch: item 4). Stages into a dedicated subfolder of
/// app documents so staged copies survive an app restart (enabling resume) —
/// unlike the temp dir, which the OS may evict.
final copypartyStagingProvider = Provider<CopypartyStagingService>((ref) {
  return CopypartyStagingService(
    ref.watch(copypartyUploaderProvider),
    logger: ref.watch(copypartyLoggerProvider),
    stagingDirProvider: () async {
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}/copyparty_staging');
    },
  );
});

// ---------------------------------------------------------------------------
// Password (stored in secure storage, not AppConfig)
// ---------------------------------------------------------------------------

final copypartyPasswordProvider = FutureProvider<String>((ref) async {
  final storage = ref.watch(secureStorageRepositoryProvider);
  return await storage.read(_copypartyPasswordKey) ?? '';
});

// ---------------------------------------------------------------------------
// Pending cleanup (uploaded files not yet deleted from device)
// ---------------------------------------------------------------------------

final pendingCleanupProvider = FutureProvider<List<CopypartyReceipt>>((ref) async {
  // Only files whose local source STILL EXISTS are pending cleanup, so the
  // settings badge count matches what the cleanup page actually lists (item 4).
  // This is a DISPLAY-ONLY filter — we must NOT mark a receipt sourceDeleted
  // here: on removable SD/USB media an unmounted card makes exists() return
  // false transiently, and persisting that would permanently drop a file that
  // is still physically present from cleanup (review: BLOCKER). "Not mounted"
  // is not "deleted".
  final repo = ref.watch(copypartyReceiptRepositoryProvider);
  final all = await repo.getUndeleted();
  final existing = <CopypartyReceipt>[];
  for (final r in all) {
    if (await File(r.localPath).exists()) {
      existing.add(r);
    }
  }
  return existing;
});

// ---------------------------------------------------------------------------
// Import session state
// ---------------------------------------------------------------------------

enum ImportSessionStep { idle, scanning, options, uploading, complete }

class ImportSessionState {
  final ImportSessionStep step;
  final String? directoryPath;
  final List<UploadSet> uploadSets;
  final int completedFiles;
  final int totalFiles;
  final int scannedFiles;
  final String? errorMessage;

  /// The file paths the user chose to upload this run. Null until upload
  /// starts (= "all"). The progress screen filters to these so deselected
  /// files are not listed during upload.
  final Set<String>? selectedPaths;

  /// True when the run reached the completion screen because the user STOPPED
  /// it (not because everything finished). Drives the "Upload stopped" header
  /// and the Resume option. (items 2/3)
  final bool cancelled;

  /// True when the user PAUSED the run: the loop has exited but the session
  /// stays on the progress page with a Resume control. (batch3 item 6)
  final bool paused;

  const ImportSessionState({
    this.step = ImportSessionStep.idle,
    this.directoryPath,
    this.uploadSets = const [],
    this.completedFiles = 0,
    this.totalFiles = 0,
    this.scannedFiles = 0,
    this.errorMessage,
    this.selectedPaths,
    this.cancelled = false,
    this.paused = false,
  });

  ImportSessionState copyWith({
    ImportSessionStep? step,
    String? directoryPath,
    List<UploadSet>? uploadSets,
    int? completedFiles,
    int? totalFiles,
    int? scannedFiles,
    String? errorMessage,
    Set<String>? selectedPaths,
    bool? cancelled,
    bool? paused,
  }) => ImportSessionState(
    step: step ?? this.step,
    directoryPath: directoryPath ?? this.directoryPath,
    uploadSets: uploadSets ?? this.uploadSets,
    completedFiles: completedFiles ?? this.completedFiles,
    totalFiles: totalFiles ?? this.totalFiles,
    scannedFiles: scannedFiles ?? this.scannedFiles,
    errorMessage: errorMessage,
    selectedPaths: selectedPaths ?? this.selectedPaths,
    cancelled: cancelled ?? this.cancelled,
    paused: paused ?? this.paused,
  );

  int get totalBytes => uploadSets.fold(0, (s, u) => s + u.totalBytes);
}

class ImportSessionNotifier extends StateNotifier<ImportSessionState> {
  final CopypartyUploaderService _uploader;
  final CopypartyReceiptRepository _receiptRepo;
  final UploadRepository _immichUploadRepo;
  final Ref _ref;

  CopypartyLogger get _log => _ref.read(copypartyLoggerProvider);
  CopypartyStagingService get _staging => _ref.read(copypartyStagingProvider);

  ImportSessionNotifier(this._uploader, this._receiptRepo, this._immichUploadRepo, this._ref)
    : super(const ImportSessionState());

  /// Cache read-ahead (cache-size feature). Files are copied from the card into
  /// the phone cache ahead of the upload loop, up to the configured cache
  /// budget, so uploads never wait on the slow card.
  ///
  /// - `_inFlightStaging` dedups by source path so the upload loop and the
  ///   read-ahead filler never copy the same file twice (they share one future).
  /// - `_stageLock` serialises the card so only ONE file is ever copied at a
  ///   time (the card is a serial device — two concurrent reads would thrash it).
  /// - `_cacheFillFuture` is the single read-ahead loop; it exits when the cache
  ///   is full or nothing is left to stage, and is restarted after a discard.
  final Map<String, Future<HashedFile?>> _inFlightStaging = {};
  Future<void>? _stageLock;
  Future<void>? _cacheFillFuture;
  // The file the upload loop is currently handling. Excluded from the read-ahead
  // filler so it can't re-stage the exact file the loop is uploading (or reading
  // direct on the staging-failed fallback) → no concurrent same-file card read.
  // (concurrency finding 2)
  String? _uploadingPath;

  /// Completed when the user cancels the in-progress upload. The uploader
  /// races its in-flight chunk POST against this, and the per-file loop checks
  /// it between files, so cancellation takes effect promptly even on a stalled
  /// connection.
  Completer<void>? _uploadCancelToken;

  /// True for the entire lifetime of one startUpload() invocation, including its
  /// teardown (which now awaits an in-flight prefetch). Gates every entry point
  /// so a SECOND upload loop can never start while one is active — which would
  /// otherwise clobber the shared cancel token and leak an uncancellable
  /// background loop. (concurrency review finding 1/4)
  bool _uploadRunning = false;

  bool get isCancelling => _uploadCancelToken?.isCompleted ?? false;

  /// Request cancellation of the current upload run. Safe to call repeatedly.
  void cancelUpload() {
    final token = _uploadCancelToken;
    if (token != null && !token.isCompleted) {
      _log.log('UPLOAD CANCEL requested by user');
      token.complete();
      _notify();
    }
  }

  /// batch3 item 6: pause. Halts the queue exactly like Stop (the current file
  /// returns to pending; already-sent chunks are remembered by the server, so
  /// Resume's re-handshake never re-uploads them) but the session STAYS on the
  /// progress page in a paused state instead of going to the completion screen.
  bool _pauseRequested = false;

  void pauseUpload() {
    if (_uploadRunning && !_pauseRequested) {
      _pauseRequested = true;
      _log.log('UPLOAD PAUSE requested by user');
      cancelUpload();
    }
  }

  /// batch3 item 6: skip the file the loop is CURRENTLY working on (copy, hash
  /// or transfer). It is marked `skipped` (not failed, not pending) and the
  /// queue moves straight on to the next file.
  Completer<void>? _skipToken;

  void skipCurrentFile(String localPath) {
    if (_uploadingPath == localPath && !(_skipToken?.isCompleted ?? true)) {
      _log.log('SKIP requested for ${localPath.split('/').last}');
      _skipToken!.complete();
      _notify();
    }
  }

  void reset() {
    cancelUpload();
    state = const ImportSessionState();
  }

  Future<void> scan(String directoryPath) async {
    state = state.copyWith(step: ImportSessionStep.scanning, directoryPath: directoryPath, scannedFiles: 0);

    // Backstop cleanup for staged copies orphaned by an app that was killed
    // mid-import and never resumed. Recent ones are kept so a near-term resume
    // can still reuse them without re-reading the source. (batch: item 4)
    unawaited(_staging.sweepStale(const Duration(days: 7), DateTime.now()));

    try {
      final config = _ref.read(appConfigProvider).copyparty;
      final pairer = CopypartyFilePairer(
        triggerExtensions: config.triggerExtensions,
        defaultNativeDestination: CopypartyFilePairer.parseDefaultDestination(config.defaultDestination),
      );
      final sets = await pairer.scanDirectory(
        directoryPath,
        onFileFound: (count) => state = state.copyWith(scannedFiles: count),
      );
      for (final set in sets) {
        set.rootPath = directoryPath;
        for (final file in set.files) {
          file.existingReceipt = await _receiptRepo.findByLocalPath(file.localPath);
        }
      }

      // A file already copied into the cache (from before the app was closed, or
      // a prior/aborted run) is marked "Copied" so a reopened import reflects the
      // cache instead of showing 0%. (cache-detect feature)
      await _detectCachedFiles(sets);

      // FB3: do NOT block the picker on a server listing here — show the file
      // list immediately and let the options step verify status lazily.
      state = state.copyWith(
        step: ImportSessionStep.options,
        uploadSets: sets,
        totalFiles: sets.fold<int>(0, (s, u) => s + u.files.length),
      );
    } catch (e) {
      state = state.copyWith(step: ImportSessionStep.idle, errorMessage: 'Scan failed: $e');
    }
  }

  Future<void> startUpload({Set<String>? selectedFilePaths}) async {
    // Never run two upload loops at once. A caller (appendSelectedSets / resume /
    // retry) that fires while a loop is still active — including during its
    // teardown await — just returns; the live loop already picks up new pending
    // files from state. Set synchronously before any await. (concurrency finding 1)
    if (_uploadRunning) {
      return;
    }
    _uploadRunning = true;

    // Keep the device awake for the whole upload. Without this, a long import
    // (multi-GB files over slow links = many minutes) gets the screen-off doze /
    // low-memory killer, and Android silently kills the in-app upload loop
    // mid-transfer — the exact "crashed, no error" the diagnostic log showed
    // (log ends mid-chunk, no Dart error). Mirrors the standard backup page.
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    // A wakelock alone wasn't enough on Samsung — see CLAUDE.md. Raise this
    // process to foreground OOM-kill priority for the duration of the import.
    await CopypartyForegroundService.start();

    final config = _ref.read(appConfigProvider).copyparty;
    // Q3: folder recreation is now a persistent setting, not a per-import flag.
    final createFolders = config.recreateFolderStructure;
    // batch item 4: copy each file to local phone storage before hashing/upload.
    final useStaging = config.stageToLocalBeforeUpload;
    final password = await _ref.read(copypartyPasswordProvider.future);
    final packageInfo = await PackageInfo.fromPlatform();

    // Log the EXACT config this run will use so the diagnostic log proves
    // whether settings (e.g. upload path) were picked up or stale-cached.
    _log.section('IMPORT SESSION  app v${packageInfo.version}');
    _log.log('config.hostUrl       = "${config.hostUrl}"');
    _log.log('config.uploadPath    = "${config.uploadPath}"');
    _log.log('config.parallelConns = ${config.parallelConnections}');
    _log.log('config.selfSigned    = ${config.allowSelfSignedCert}');
    _log.log('config.stageToLocal  = ${config.stageToLocalBeforeUpload}');
    _log.log('config.cacheSizeMb   = ${config.cacheSizeMb}');
    _log.log('password set         = ${password.isNotEmpty}');
    _log.log('files selected       = ${selectedFilePaths?.length ?? state.totalFiles}');

    final effectiveTotal = selectedFilePaths != null ? selectedFilePaths.length : state.totalFiles;

    final cancelToken = _uploadCancelToken = Completer<void>();

    state = state.copyWith(
      step: ImportSessionStep.uploading,
      completedFiles: 0,
      totalFiles: effectiveTotal,
      selectedPaths: selectedFilePaths,
      cancelled: false,
      paused: false,
    );
    _pauseRequested = false;

    // Single persistent listener on the SESSION-long cancelToken.future, rather
    // than one per file: a per-file `.then()` registration on this same
    // long-lived Future would accumulate one closure per file for the entire
    // session (never released until cancel/crash) — real growth on a
    // thousand-file import, the exact kind of pressure behind the earlier OOM
    // crashes. `_currentFileToken` is repointed each iteration; this one
    // subscription completes whichever file's token is current. (batch3 item 6)
    Completer<void>? currentFileToken;
    unawaited(
      cancelToken.future.then((_) {
        final t = currentFileToken;
        if (t != null && !t.isCompleted) {
          t.complete();
        }
      }),
    );

    // Dynamic queue loop: on each iteration pick the next SELECTED + PENDING
    // file from the LIVE state, so folders added mid-run via addFolders() are
    // picked up. When "upload smallest first" is on we take the pending file
    // from the smallest group. (item 2 + item 4)
    bool cancelled = false;
    try {
      while (true) {
        if (cancelToken.isCompleted) {
          cancelled = true;
          break;
        }
        final sel = state.selectedPaths;
        final candidates = <({UploadSet set, UploadFile file})>[];
        for (final s in state.uploadSets) {
          for (final f in s.files) {
            if (sel != null && !sel.contains(f.localPath)) {
              continue;
            }
            if (f.status != UploadFileStatus.pending) {
              continue;
            }
            candidates.add((set: s, file: f));
          }
        }
        if (candidates.isEmpty) {
          break;
        }
        if (config.sortSmallestFirst) {
          candidates.sort((a, b) => a.set.totalBytes.compareTo(b.set.totalBytes));
        }
        final set = candidates.first.set;
        final file = candidates.first.file;
        // Mark it as the loop's current file so the read-ahead filler excludes
        // it (concurrency finding 2).
        _uploadingPath = file.localPath;
        _logMemory('start ${file.filename}');
        // batch3 item 6: per-file token that fires on session-cancel OR skip.
        // The network/hash calls for THIS file abort on it; the catch below
        // tells the two apart (skip → mark skipped + continue; cancel → break).
        final skip = _skipToken = Completer<void>();
        final fileToken = Completer<void>();
        currentFileToken = fileToken;
        void completeFileToken(void _) {
          if (!fileToken.isCompleted) {
            fileToken.complete();
          }
        }

        unawaited(skip.future.then(completeFileToken));
        {
          // FB9: when "create folders" is on, mirror the file's subfolder beneath
          // the upload path, rooted at the set's OWN picked folder (so added
          // folders mirror correctly, not against the first pick's root).
          final uploadPath =
              file.uploadPathOverride ??
              (createFolders
                  ? mirroredUploadPath(config.uploadPath, set.rootPath ?? state.directoryPath, file.localPath)
                  : config.uploadPath);
          int? receiptId;
          final fileSizeBytes = file.sizeBytes;
          // Stage the file to local phone storage first (copy + hash in one USB
          // read pass) when enabled — then upload from the fast local copy. Null
          // means "read directly from the source" (staging off, or it failed /
          // ran out of space → automatic fallback). (batch: item 4)
          HashedFile? staged;
          try {
            if (useStaging && (file.needsCopyparty || file.needsImmich)) {
              // Race the (possibly long) card copy against skip so Skip works
              // during the copy phase too. On skip the underlying copy carries
              // on in the background exactly like a filler prefetch — its result
              // stays in the cache for a later retry. (batch3 item 6)
              staged = await Future.any<HashedFile?>([
                _acquireStaged(file, cancelToken),
                skip.future.then<HashedFile?>((_) => null),
              ]);
              if (skip.isCompleted && !cancelToken.isCompleted) {
                throw const CopypartyCancelledException();
              }
            }
            // Copy phase is over for THIS file — clear the flags so the card
            // stops showing "Copying"/"Copied" regardless of which backend runs next.
            file.staging = false;
            file.stagedReady = false;

            // Card removed? A file with a complete staged copy continues from the
            // phone; a file WITHOUT one fails fast with a clear message instead of
            // letting a dead-mount read throw deep inside the upload pipeline —
            // and the loop moves on to the remaining (staged) files. (unmount bug)
            if (staged == null) {
              var sourceAvailable = false;
              try {
                sourceAvailable = await File(file.localPath).exists();
              } catch (_) {}
              if (!sourceAvailable) {
                file.status = UploadFileStatus.failed;
                file.errorMessage = 'Source unavailable (memory card removed?) — reconnect the card and retry';
                _log.log('!! SOURCE GONE ${file.filename}: no staged copy, skipping');
                _notify();
                continue;
              }
            }
            final readPath = staged?.path ?? file.localPath;

            // Keep the read-ahead cache filler running so the following files
            // copy from the card into the cache (up to the cache budget) while
            // this one uploads over the network. (cache-size feature)
            if (useStaging) {
              _startCacheFiller(cancelToken);
            }

            // ---- Copyparty upload ----
            if (file.needsCopyparty) {
              file.staging = false;
              // A staged file is already hashed → it's now handshaking, not
              // hashing; reset the bar so it doesn't flash "hashing 100%".
              file.status = staged != null ? UploadFileStatus.handshaking : UploadFileStatus.hashing;
              file.uploadedBytes = 0;
              _notify();

              void onUp(int done, int total) {
                // POSTing chunks to copyparty — flip to `uploading` so the phase
                // chip changes to "Copyparty". The bar fills 0→100% over upload.
                file.status = UploadFileStatus.uploading;
                file.transferStartMs ??= DateTime.now().millisecondsSinceEpoch;
                final chunkProgress = total > 0 ? done / total : 0.0;
                file.uploadedBytes = (fileSizeBytes * chunkProgress).round();
                _notify();
              }

              final HashedFile hashed;
              final HandshakeResult confirmed;
              final bool alreadyOnServer;
              if (staged != null) {
                // Already hashed during staging — go straight to handshake/upload.
                hashed = staged;
                final (res, already) = await _uploader.uploadHashedFile(
                  staged,
                  config.hostUrl,
                  uploadPath,
                  password,
                  parallelism: config.parallelConnections,
                  onUploadProgress: onUp,
                  cancelToken: fileToken,
                );
                confirmed = res;
                alreadyOnServer = already;
              } else {
                // Direct-from-source path: hash + upload in one call as before.
                final (h, res, already) = await _uploader.uploadFile(
                  readPath,
                  config.hostUrl,
                  uploadPath,
                  password,
                  parallelism: config.parallelConnections,
                  onHashProgress: (done, total) {
                    file.status = UploadFileStatus.hashing;
                    file.uploadedBytes = done;
                    _notify();
                  },
                  onUploadProgress: onUp,
                  cancelToken: fileToken,
                );
                hashed = h;
                confirmed = res;
                alreadyOnServer = already;
              }

              file.sha512 = hashed.fileHash;
              file.wark = confirmed.wark;
              file.uploadedBytes = file.sizeBytes;
              file.alreadyOnServer = alreadyOnServer;
              file.status = UploadFileStatus.confirmed;

              // Record the ACTUAL folder this file went to (mirrored sub-path
              // under FB9) so the completion-screen delete re-verifies the right
              // location, not the flat base path. (Review BLOCKER 1)
              final uploadFolderUrl = '${config.hostUrl.trimRight()}/${_stripSlashes(uploadPath)}';
              file.uploadFolderUrl = uploadFolderUrl;

              // Write DB receipt — upload_confirmed=true since uploadFile() only
              // returns successfully after the confirmation handshake passes.
              final uploadUrl = '$uploadFolderUrl/${file.filename}';
              receiptId = await _receiptRepo.insert(
                CopypartyReceipt(
                  filename: file.filename,
                  localPath: file.localPath,
                  sizeBytes: file.sizeBytes,
                  sha512File: hashed.fileHash,
                  wark: confirmed.wark,
                  uploadTimestamp: DateTime.now().toUtc(),
                  copypartyUrl: uploadUrl,
                  uploadConfirmed: true,
                ),
              );
              file.dbRecordWritten = true;
              // Re-upload of a tracked file: the fresh receipt supersedes the
              // old row so Pending Cleanup doesn't show duplicates. (item 18)
              final oldReceiptId = file.existingReceipt?.id;
              if (oldReceiptId != null && oldReceiptId != receiptId) {
                try {
                  await _receiptRepo.markSourceDeleted(oldReceiptId);
                } catch (_) {}
              }

              // FB11: the .cpreceipt sidecar file is redundant now that presence
              // is verified live against the server; we no longer write it. The
              // DB receipt (above) remains — Pending Cleanup needs it.
            }

            // ---- Immich native upload ----
            if (file.needsImmich) {
              file.status = UploadFileStatus.immichUploading;
              file.uploadedBytes = 0;
              file.transferStartMs ??= DateTime.now().millisecondsSinceEpoch;
              _notify();

              final result = await _uploadToImmich(file, fileToken, staged?.path);
              if (result.isSuccess) {
                file.immichAssetId = result.remoteAssetId;
                if (receiptId != null && result.remoteAssetId != null) {
                  await _receiptRepo.markImmichUploaded(receiptId, result.remoteAssetId!);
                }
              } else if (result.isCancelled || fileToken.isCompleted) {
                // Cancelled during the Immich upload → stop like a copyparty cancel.
                throw const CopypartyCancelledException();
              } else {
                throw Exception(result.errorMessage ?? 'Immich upload failed');
              }
            }

            // Auto-delete after BOTH backends are done (item 5): safeToDelete
            // already requires the Immich asset id for Immich-native files, so a
            // "both"/Immich file is only removed once it's confirmed in Immich —
            // not just on copyparty. Runs for copyparty-only files too.
            if (config.autoDeleteAfterVerify && file.safeToDelete && receiptId != null) {
              // When we uploaded from a STAGED copy the source was read only once,
              // so a transient read corruption would be self-consistent (its hash
              // matches the corrupt bytes the server accepted). Before the
              // IRREVERSIBLE source delete, re-read the source once and confirm it
              // still matches what we uploaded. This restores the cross-check the
              // direct (double-read) path gets for free. (data-integrity finding 2)
              var safeToRemove = true;
              if (staged != null) {
                try {
                  final srcHash = await _wholeFileSha512(file.localPath);
                  safeToRemove = srcHash == file.sha512;
                  if (!safeToRemove) {
                    _log.log(
                      'AUTO-DELETE BLOCKED for ${file.filename}: source hash != uploaded hash '
                      '(possible bad read) — keeping the source file',
                    );
                  }
                } catch (_) {
                  // Source unreadable (e.g. card pulled) → nothing to delete anyway.
                  safeToRemove = false;
                }
              }
              if (safeToRemove) {
                try {
                  await File(file.localPath).delete();
                  await _receiptRepo.markSourceDeleted(receiptId);
                } catch (_) {}
              }
            }

            // Freeze the transfer duration so "total · elapsed · avg" is stable in
            // the UI (a file that never transferred — already on server — keeps
            // both timestamps null and shows no timing). (batch: item 2)
            if (file.transferStartMs != null && !file.alreadyOnServer) {
              file.transferEndMs = DateTime.now().millisecondsSinceEpoch;
            }
            file.status = UploadFileStatus.receiptWritten;
            // Fully confirmed on all needed backends → the local staged copy has
            // done its job; reclaim the space. (Only on SUCCESS — an interrupted
            // upload keeps its staged copy so it can resume without re-reading
            // the source.) (batch: item 4)
            if (staged != null) {
              await _staging.discard(file.localPath);
              file.stagedReady = false;
              // Space freed → let the read-ahead filler resume if it had paused
              // because the cache was full. (cache-size feature)
              if (useStaging) {
                _startCacheFiller(cancelToken);
              }
            }
            state = state.copyWith(completedFiles: state.completedFiles + 1);
          } on CopypartyCancelledException {
            if (!cancelToken.isCompleted && skip.isCompleted) {
              // SKIP (batch3 item 6): mark this file skipped — not failed, not
              // pending — and move straight on to the next file. Any staged copy
              // stays cached for a later retry.
              file.staging = false;
              file.status = UploadFileStatus.skipped;
              file.uploadedBytes = 0;
              _log.log('-- SKIPPED ${file.filename}');
              _notify();
              continue;
            }
            // User cancelled mid-file: leave it pending (not failed) so it can be
            // resumed cleanly next run, and stop the loop. The staged copy (if any)
            // is intentionally KEPT for a fast resume.
            file.staging = false;
            file.status = UploadFileStatus.pending;
            file.uploadedBytes = 0;
            cancelled = true;
            _log.log('-- CANCELLED at ${file.filename}');
            _notify();
            break;
          } catch (e) {
            file.staging = false;
            file.status = UploadFileStatus.failed;
            file.errorMessage = e.toString();
            _log.log('!! FAILED ${file.filename}: $e');
            _notify();
          }
        }
      }
    } catch (e, st) {
      // Any error that escapes the per-file handler (candidate selection,
      // discard, a notify, an unexpected state error) would otherwise vanish
      // with the app. Log it AND force it to disk so a crash leaves a trace.
      _log.log('!!!! UPLOAD LOOP CRASHED: $e\n$st');
      cancelled = true;
      // Complete the token so the read-ahead filler and every in-flight copy
      // (which loop on `!cancelToken.isCompleted`) stop promptly — otherwise
      // teardown would block draining the whole cache and a filler could outlive
      // this dead loop into the next resume. (concurrency finding 1)
      if (!cancelToken.isCompleted) {
        cancelToken.complete();
      }
      try {
        await _log.flush();
      } catch (_) {}
    } finally {
      // Teardown ALWAYS runs (even on an unexpected throw) so _uploadRunning and
      // the cancel token can't get stuck true → a wedged, unrestartable session.
      // Because _uploadRunning gated entry, this invocation is the sole owner of
      // the shared state here; no second loop can have started. (concurrency finding 1)
      //
      // Settle the read-ahead cache filler and every in-flight card copy before
      // returning. On cancel each copy holds the now-completed token, aborts
      // within a chunk and self-deletes its partial, so awaiting them guarantees
      // no detached writer survives into a later resume. (review finding 2)
      final filler = _cacheFillFuture;
      if (filler != null) {
        try {
          await filler;
        } catch (_) {}
      }
      for (final copy in List<Future<HashedFile?>>.of(_inFlightStaging.values)) {
        try {
          await copy;
        } catch (_) {}
      }
      _uploadCancelToken = null;
      _uploadRunning = false;
      _uploadingPath = null;
      _skipToken = null;
      final wasPaused = _pauseRequested;
      _pauseRequested = false;
      try {
        await WakelockPlus.disable();
      } catch (_) {}
      await CopypartyForegroundService.stop();
      _log.log(
        'IMPORT SESSION ${wasPaused ? 'paused' : (cancelled ? 'cancelled' : 'complete')}: '
        '${state.completedFiles}/${state.totalFiles} files done',
      );
      // Only advance to the completion screen if we're still uploading — a
      // concurrent reset() (e.g. the user left the page) must not be clobbered.
      if (state.step == ImportSessionStep.uploading) {
        if (wasPaused) {
          // batch3 item 6: PAUSE keeps the session on the progress page with a
          // Resume control instead of jumping to the completion screen.
          state = state.copyWith(paused: true);
        } else {
          state = state.copyWith(step: ImportSessionStep.complete, cancelled: cancelled);
        }
      }
    }
  }

  /// Logs the app's resident memory (RSS). A silent crash that also kills other
  /// apps (e.g. the VPN) is a system-wide OOM; this shows whether OUR process is
  /// the one growing (a leak) or staying flat (pressure from elsewhere / disk
  /// dirty pages). Cheap — safe to call per file. (crash instrumentation)
  void _logMemory(String tag) {
    try {
      final rssMib = (ProcessInfo.currentRss / (1024 * 1024)).round();
      final cacheMib = _lastCacheBytes ~/ (1024 * 1024);
      _log.log('MEM $tag  rss=${rssMib}MiB  cacheOnDisk≈${cacheMib}MiB');
    } catch (_) {}
  }

  int _lastCacheBytes = 0;

  /// Returns a local staged [HashedFile] for [file], or null to upload directly
  /// from the source (staging off / failed / out of space → fallback). Shares
  /// the in-flight-staging dedup so if the read-ahead filler is already copying
  /// this file, the loop awaits the SAME copy instead of starting a second one.
  Future<HashedFile?> _acquireStaged(UploadFile file, Completer<void> cancelToken) {
    return _ensureStaged(file, cancelToken);
  }

  /// Copies [file] into the cache exactly once: if a copy for this source path
  /// is already in flight (started by the loop or the filler) return that same
  /// future; otherwise start one. The actual copy runs under [_stageLock] so
  /// only one card read happens at a time.
  Future<HashedFile?> _ensureStaged(UploadFile file, Completer<void> cancelToken) {
    final existing = _inFlightStaging[file.localPath];
    if (existing != null) {
      return existing;
    }
    final fut = _doStageLocked(file, cancelToken);
    _inFlightStaging[file.localPath] = fut;
    unawaited(
      fut.whenComplete(() {
        if (identical(_inFlightStaging[file.localPath], fut)) {
          _inFlightStaging.remove(file.localPath);
        }
      }),
    );
    return fut;
  }

  Future<HashedFile?> _doStageLocked(UploadFile file, Completer<void> cancelToken) async {
    if (cancelToken.isCompleted) {
      return null;
    }
    // FAST PATH — reuse an existing valid cache copy WITHOUT taking the card
    // lock. Reading the marker is a quick local check that never touches the
    // card, so an already-staged file uploads immediately instead of queueing
    // behind the read-ahead filler's in-flight copy. (fixes "uploads waiting for
    // a copy to complete" — the card lock previously serialised even cache hits.)
    try {
      final existing = await _staging.findValidStaged(file.localPath);
      if (existing != null) {
        file.staging = false;
        file.stagedReady = true;
        _notify();
        return existing;
      }
    } catch (_) {}
    if (cancelToken.isCompleted) {
      return null;
    }
    // SLOW PATH — an actual card read. Serialise it behind any other in-flight
    // copy so only ONE card read happens at a time (the card is serial).
    return _copyFromCardLocked(file, cancelToken);
  }

  Future<HashedFile?> _copyFromCardLocked(UploadFile file, Completer<void> cancelToken) {
    final prev = _stageLock;
    final done = Completer<void>();
    _stageLock = done.future;
    return () async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {}
      }
      try {
        if (cancelToken.isCompleted) {
          return null;
        }
        final hashed = await _staging.stage(
          file.localPath,
          cancelToken: cancelToken,
          onProgress: (bytesCopied, total) {
            // Drive the card's "Copying to phone N%" WITHOUT changing status —
            // the file must stay `pending` so the upload loop still picks it.
            file.staging = true;
            file.stagedReady = false;
            file.uploadedBytes = bytesCopied;
            _notify();
          },
        );
        // Copy AND hash are done (hashing happens during the copy) → "Copied".
        file.staging = false;
        file.stagedReady = true;
        _notify();
        return hashed;
      } on CopypartyCancelledException {
        file.staging = false;
        file.stagedReady = false;
        file.uploadedBytes = 0;
        _notify();
        return null;
      } catch (e) {
        // Out of space / IO error → fall back to reading direct from the card.
        _log.log('staging failed for ${file.filename}: $e — reading direct from source');
        file.staging = false;
        file.stagedReady = false;
        file.uploadedBytes = 0;
        _notify();
        return null;
      } finally {
        done.complete();
        if (identical(_stageLock, done.future)) {
          _stageLock = null;
        }
      }
    }();
  }

  /// Starts the read-ahead cache filler if it isn't already running. The filler
  /// copies pending files into the cache ahead of the upload loop, in upload
  /// order, until the cache budget (config.cacheSizeMb) is full or nothing is
  /// left to stage — then it exits and is restarted after a discard frees space.
  /// (cache-size feature)
  void _startCacheFiller(Completer<void> cancelToken) {
    if (_cacheFillFuture != null) {
      return;
    }
    if (!_ref.read(appConfigProvider).copyparty.stageToLocalBeforeUpload) {
      return;
    }
    _cacheFillFuture = _fillCache(cancelToken).whenComplete(() => _cacheFillFuture = null);
  }

  Future<void> _fillCache(Completer<void> cancelToken) async {
    while (!cancelToken.isCompleted) {
      final config = _ref.read(appConfigProvider).copyparty;
      if (!config.stageToLocalBeforeUpload) {
        return;
      }
      final budget = config.cacheSizeMb * 1024 * 1024;
      final sel = state.selectedPaths;

      // Pick the next file to read ahead, in upload order (smallest-first
      // honoured), skipping ones already staged/in-flight and the file the
      // upload loop is currently handling (concurrency finding 2).
      final candidates = <UploadFile>[];
      final owner = <UploadFile, UploadSet>{};
      for (final s in state.uploadSets) {
        for (final f in s.files) {
          if (f.status != UploadFileStatus.pending || f.stagedReady) {
            continue;
          }
          if (f.localPath == _uploadingPath || _inFlightStaging.containsKey(f.localPath)) {
            continue;
          }
          if (sel != null && !sel.contains(f.localPath)) {
            continue;
          }
          candidates.add(f);
          owner[f] = s;
        }
      }
      if (candidates.isEmpty) {
        return;
      }
      if (config.sortSmallestFirst) {
        candidates.sort((a, b) => owner[a]!.totalBytes.compareTo(owner[b]!.totalBytes));
      }
      final next = candidates.first;

      // Budget against the ACTUAL bytes on disk (data-integrity + concurrency
      // finding 3): the in-memory stagedReady tally under-counted the file
      // currently uploading (its copy is still on disk) and in-flight partials,
      // letting the cache overshoot the cap. currentCacheBytes() sums the real
      // staging dir. Always allow at least one file (used==0) so a single file
      // bigger than the whole cache still stages one-at-a-time; otherwise stop
      // and wait for an upload to discard and free space (which restarts us).
      final used = await _staging.currentCacheBytes();
      _lastCacheBytes = used;
      if (cancelToken.isCompleted) {
        return;
      }
      if (used > 0 && used + next.sizeBytes > budget) {
        return;
      }
      final result = await _ensureStaged(next, cancelToken);
      // A staging failure (out of space / IO) resolves to null — stop filling so
      // we don't spin in a tight fail loop; the loop will fall back per-file.
      if (result == null && !next.stagedReady) {
        return;
      }
    }
  }

  /// Live name/size verification for [sets] against their target server folders
  /// (same listing logic as the options step, minus the heavy Immich-by-checksum
  /// pass). Used by the add-folders selection page and after appending sets so
  /// their group summaries resolve instead of sitting on "checking server…"
  /// forever. Safe to call fire-and-forget; failures leave states unknown.
  /// (batch3 item 13)
  Future<void> verifySetsAgainstServer(List<UploadSet> sets) async {
    try {
      final config = _ref.read(appConfigProvider).copyparty;
      final uploader = _ref.read(copypartyUploaderProvider);
      String password = '';
      try {
        password = await _ref.read(copypartyPasswordProvider.future);
      } catch (_) {}
      final listings = <String, Map<String, int>>{};
      for (final set in sets) {
        for (final file in set.files) {
          final folder = config.recreateFolderStructure
              ? mirroredUploadPath(config.uploadPath, set.rootPath ?? state.directoryPath, file.localPath)
              : config.uploadPath;
          if (!listings.containsKey(folder)) {
            try {
              listings[folder] = await uploader.listUploadFolder(config.hostUrl, folder, password);
            } on CopypartyUploadException {
              // Folder doesn't exist yet on the server → nothing uploaded there.
              listings[folder] = const <String, int>{};
            }
          }
          file.verification = CopypartyUploaderService.verificationFromListing(
            listings[folder] ?? const {},
            file.filename,
            file.sizeBytes,
            immichApplicable: CopypartyFilePairer.isNativeImmichFilename(file.filename),
          );
        }
      }
      _notify();
    } catch (e) {
      // Genuine connection failure — leave verification unknown; the UI shows
      // the unresolved state rather than a stale/false "checking…".
      _log.log('verifySetsAgainstServer failed: $e');
      _notify();
    }
  }

  /// Marks files that already have a valid cache copy as "Copied" so a reopened
  /// import reflects the cache instead of showing 0%. (cache-detect feature)
  Future<void> _detectCachedFiles(List<UploadSet> sets) async {
    for (final set in sets) {
      for (final file in set.files) {
        try {
          final existing = await _staging.findValidStaged(file.localPath);
          if (existing != null) {
            file.stagedReady = true;
            file.uploadedBytes = file.sizeBytes;
          }
        } catch (_) {}
      }
    }
  }

  /// Resume a stopped run (item 3): re-runs the upload loop for the files still
  /// pending in the current selection (already-done files are skipped).
  Future<void> resumeUpload() async {
    await startUpload(selectedFilePaths: state.selectedPaths);
  }

  /// Scan folders WITHOUT touching the live session (item 4): returns the found
  /// upload sets (rootPath set, receipts loaded) so a selection page can let the
  /// user pick before anything is appended to the ongoing task.
  Future<List<UploadSet>> scanFolders(List<String> directoryPaths) async {
    final config = _ref.read(appConfigProvider).copyparty;
    final pairer = CopypartyFilePairer(
      triggerExtensions: config.triggerExtensions,
      defaultNativeDestination: CopypartyFilePairer.parseDefaultDestination(config.defaultDestination),
    );
    final newSets = <UploadSet>[];
    // De-dup against files already queued so re-picking a folder can't double it.
    final existing = state.uploadSets.expand((s) => s.files).map((f) => f.localPath).toSet();
    for (final dir in directoryPaths) {
      final sets = await pairer.scanDirectory(dir);
      for (final set in sets) {
        set.rootPath = dir;
        set.files.removeWhere((f) => existing.contains(f.localPath));
        for (final file in set.files) {
          file.existingReceipt = await _receiptRepo.findByLocalPath(file.localPath);
        }
      }
      newSets.addAll(sets.where((s) => s.files.isNotEmpty));
    }
    return newSets;
  }

  /// Append user-selected files from already-scanned sets to the live queue and
  /// selection (item 4). Only [selectedPaths] are marked for upload; unselected
  /// files still show in the group but stay out of the selection. If no upload
  /// is currently running, kicks one off for the merged selection.
  Future<void> appendSelectedSets(List<UploadSet> newSets, Set<String> selectedPaths) async {
    // Keep only sets that contributed at least one selected file, so the queue
    // isn't cluttered with fully-deselected groups.
    final keptSets = newSets.where((s) => s.files.any((f) => selectedPaths.contains(f.localPath))).toList();
    final addedPaths = keptSets.expand((s) => s.files).map((f) => f.localPath).where(selectedPaths.contains).toSet();
    if (addedPaths.isEmpty) {
      return;
    }

    _log.log('ADD FOLDERS: +${keptSets.length} set(s), +${addedPaths.length} selected file(s)');
    // Reflect any already-cached copies among the added files as "Copied".
    await _detectCachedFiles(keptSets);
    // Resolve the appended groups' server status in the background so their
    // summaries don't sit on "checking server…" forever. (batch3 item 13)
    unawaited(verifySetsAgainstServer(keptSets));
    state = state.copyWith(
      uploadSets: [...state.uploadSets, ...keptSets],
      selectedPaths: {...?state.selectedPaths, ...addedPaths},
      totalFiles: state.totalFiles + addedPaths.length,
    );
    _notify();

    // If a loop is already running it will pick up the newly-appended pending
    // files from state on its next iteration; otherwise kick one off for the
    // merged selection. Gated on _uploadRunning (not the cancel-token state) so
    // it can't spawn a second loop during a teardown window. (concurrency finding 1)
    if (!_uploadRunning) {
      await startUpload(selectedFilePaths: state.selectedPaths);
    } else {
      // Loop already running — nudge the read-ahead filler in case it had exited
      // (cache full / nothing left) before these files were added. (cache-size)
      final token = _uploadCancelToken;
      if (token != null && !token.isCompleted) {
        _startCacheFiller(token);
      }
    }
  }

  /// batch3 item 20: queue files straight from the phone cache into the live
  /// upload (or start one). Sets are built from the cache markers' metadata, so
  /// this works even when the original card is no longer attached — the bytes
  /// come from the cache; the receipt still records the ORIGINAL source path.
  Future<void> queueCachedFiles(List<StagedCacheEntry> entries) async {
    final existing = state.uploadSets.expand((s) => s.files).map((f) => f.localPath).toSet();
    final config = _ref.read(appConfigProvider).copyparty;
    final defaultDest = CopypartyFilePairer.parseDefaultDestination(config.defaultDestination);
    final newSets = <UploadSet>[];
    final paths = <String>{};
    for (final e in entries) {
      if (existing.contains(e.sourcePath)) {
        continue;
      }
      final native = CopypartyFilePairer.isNativeImmichFilename(e.filename);
      final parent = e.sourcePath.substring(0, e.sourcePath.lastIndexOf('/') < 0 ? 0 : e.sourcePath.lastIndexOf('/'));
      final file = UploadFile(
        localPath: e.sourcePath,
        filename: e.filename,
        sizeBytes: e.sizeBytes,
        lastModifiedMs: e.modified.millisecondsSinceEpoch,
        isNativeImmichFile: native,
        destination: native ? defaultDest : UploadDestination.copypartyOnly,
      );
      file.existingReceipt = await _receiptRepo.findByLocalPath(e.sourcePath);
      newSets.add(UploadSet(files: [file], directoryPath: parent, rootPath: parent));
      paths.add(e.sourcePath);
    }
    if (paths.isEmpty) {
      return;
    }
    _log.log('QUEUE FROM CACHE: +${paths.length} file(s)');
    await appendSelectedSets(newSets, paths);
  }

  /// batch3 item 18: queue receipt re-uploads (cleanup "Upload now") into the
  /// live import so they show on the active-uploads pages, preserving each
  /// receipt's ORIGINAL server folder via uploadPathOverride (review L1).
  Future<void> queueReceiptUploads(List<CopypartyReceipt> receipts) async {
    final existing = state.uploadSets.expand((s) => s.files).map((f) => f.localPath).toSet();
    final newSets = <UploadSet>[];
    final paths = <String>{};
    for (final r in receipts) {
      if (existing.contains(r.localPath)) {
        continue;
      }
      String uploadPath;
      try {
        final uri = Uri.parse(r.copypartyUrl);
        final segs = List<String>.from(uri.pathSegments)..removeWhere((seg) => seg.isEmpty);
        if (segs.isNotEmpty) {
          segs.removeLast(); // drop the filename
        }
        uploadPath = '/${segs.join('/')}';
      } catch (_) {
        uploadPath = _ref.read(appConfigProvider).copyparty.uploadPath;
      }
      final native = CopypartyFilePairer.isNativeImmichFilename(r.filename);
      final parent = r.localPath.substring(0, r.localPath.lastIndexOf('/') < 0 ? 0 : r.localPath.lastIndexOf('/'));
      final file = UploadFile(
        localPath: r.localPath,
        filename: r.filename,
        sizeBytes: r.sizeBytes,
        lastModifiedMs: r.uploadTimestamp.millisecondsSinceEpoch,
        isNativeImmichFile: native,
        destination: native ? UploadDestination.both : UploadDestination.copypartyOnly,
      );
      file.uploadPathOverride = uploadPath;
      file.existingReceipt = r;
      newSets.add(UploadSet(files: [file], directoryPath: parent, rootPath: parent));
      paths.add(r.localPath);
    }
    if (paths.isEmpty) {
      return;
    }
    _log.log('QUEUE RECEIPT RE-UPLOAD: +${paths.length} file(s)');
    await appendSelectedSets(newSets, paths);
  }

  /// Retry just the files that failed in the last run (item 3): reset them to
  /// pending and re-run the normal upload loop for only those files.
  Future<void> retryFailed() async {
    final failedPaths = <String>{};
    for (final set in state.uploadSets) {
      for (final file in set.files) {
        if (file.status == UploadFileStatus.failed) {
          file.status = UploadFileStatus.pending;
          file.errorMessage = null;
          file.uploadedBytes = 0;
          failedPaths.add(file.localPath);
        }
      }
    }
    if (failedPaths.isEmpty) {
      return;
    }
    await startUpload(selectedFilePaths: failedPaths);
  }

  /// Diagnostic self-test: uploads each selected file under several controlled
  /// variations so the cause of upload failures can be isolated from hard data
  /// instead of theory. Variations per file:
  ///   • orig       — original name + content (baseline)
  ///   • rename     — new name, SAME content  (does the wark change?)
  ///   • newcontent — new name + appended bytes → a brand-new wark the server
  ///                  has never seen (the real test of "a fresh upload works")
  ///   • newfolder  — new content into a fresh subfolder
  /// Everything is written to the diagnostic log; results are returned for UI.
  Future<List<UploadAttemptResult>> runSelfTest(List<String> filePaths) async {
    final config = _ref.read(appConfigProvider).copyparty;
    final password = await _ref.read(copypartyPasswordProvider.future);
    final packageInfo = await PackageInfo.fromPlatform();
    final stamp = DateTime.now().millisecondsSinceEpoch;

    _log.section('SELF-TEST SUITE  app v${packageInfo.version}');
    _log.log(
      'host=${config.hostUrl}  uploadPath=${config.uploadPath}  '
      'files=${filePaths.length}  stamp=$stamp',
    );

    final tmp = await getTemporaryDirectory();
    final results = <UploadAttemptResult>[];

    Future<void> attempt(String path, String uploadPath, String label, {bool sequential = false}) async {
      results.add(
        await _uploader.runInstrumentedUpload(
          filePath: path,
          hostUrl: config.hostUrl,
          uploadPath: uploadPath,
          password: password,
          label: label,
          parallelism: config.parallelConnections,
          sequential: sequential,
        ),
      );
    }

    for (final path in filePaths) {
      final base = path.split('/').last;
      final dot = base.lastIndexOf('.');
      final stem = dot > 0 ? base.substring(0, dot) : base;
      final ext = dot > 0 ? base.substring(dot) : '';

      // 1. baseline — original name + content
      await attempt(path, config.uploadPath, 'orig:$base');

      // 2. renamed copy, SAME bytes
      File? renamed;
      try {
        renamed = await File(path).copy('${tmp.path}/${stem}__rn$stamp$ext');
        await attempt(renamed.path, config.uploadPath, 'rename:$base');
      } catch (e) {
        _log.log('rename variation setup failed: $e');
      }

      // 3 & 4. new name + appended bytes → brand-new wark (parallel upload)
      File? newc;
      try {
        newc = await File(path).copy('${tmp.path}/${stem}__nc$stamp$ext');
        await newc.writeAsBytes(utf8.encode('\n#immich-selftest-$stamp\n'), mode: FileMode.append);
        await attempt(newc.path, config.uploadPath, 'newcontent:$base');
        await attempt(newc.path, '${config.uploadPath}/selftest_$stamp', 'newfolder:$base');
      } catch (e) {
        _log.log('newcontent variation setup failed: $e');
      }

      // 5. fresh wark uploaded SEQUENTIALLY in-order (parallelism=1). Head-to-head
      // with the parallel #3 above: if this PASSES where parallel FAILS, the
      // server mis-places concurrent/out-of-order chunks.
      File? seqc;
      try {
        seqc = await File(path).copy('${tmp.path}/${stem}__sq$stamp$ext');
        await seqc.writeAsBytes(utf8.encode('\n#immich-selftest-SEQ-$stamp\n'), mode: FileMode.append);
        await attempt(seqc.path, config.uploadPath, 'seq-newcontent:$base', sequential: true);
      } catch (e) {
        _log.log('sequential variation setup failed: $e');
      }

      try {
        await renamed?.delete();
      } catch (_) {}
      try {
        await newc?.delete();
      } catch (_) {}
      try {
        await seqc?.delete();
      } catch (_) {}
    }

    _log.section('SELF-TEST SUMMARY');
    for (final r in results) {
      _log.log(r.summaryLine);
    }
    return results;
  }

  /// Verification self-test: runs the FULL live verification (name/size/partial
  /// from `?ls`, content hash via handshake, Immich by checksum) for each file
  /// and logs a clear pass/fail summary. Lets the cleanup/verification logic be
  /// validated empirically in one shot instead of round-tripping. Returns the
  /// human-readable summary lines.
  Future<List<String>> runVerificationSelfTest(List<String> filePaths) async {
    final config = _ref.read(appConfigProvider).copyparty;
    final password = await _ref.read(copypartyPasswordProvider.future);
    final api = _ref.read(apiServiceProvider).assetsApi;
    final now = DateTime.now();

    _log.section('VERIFICATION SELF-TEST  (${filePaths.length} files)');
    final lines = <String>[];
    Map<String, int> sizes;
    try {
      sizes = await _uploader.listUploadFolder(config.hostUrl, config.uploadPath, password);
    } catch (e) {
      _log.log('listing failed: $e');
      sizes = {};
    }

    for (final path in filePaths) {
      final name = path.split('/').last;
      final fileUrl = '${config.hostUrl.trimRight()}/${_stripSlashes(config.uploadPath)}/$name';
      try {
        final size = await File(path).length();
        var v = CopypartyUploaderService.verificationFromListing(sizes, name, size);
        v = await _uploader.verifyHash(fileUrl: fileUrl, localPath: path, password: password, base: v);
        final applicable = CopypartyFilePairer.isNativeImmichFilename(name);
        VerifyState immich = VerifyState.unknown;
        if (applicable) {
          try {
            immich = (await immichAssetIdByChecksum(api, path)) != null ? VerifyState.yes : VerifyState.no;
          } catch (_) {}
        }
        v = v.copyWith(immich: immich, immichApplicable: applicable);
        final line =
            '$name → name=${v.filenamePresent.name} '
            'size=${v.sizeMatches.name} partial=${v.partialExists.name} '
            'hash=${v.hashFreshAt(now) ? "ok" : "no"} immich=${immich.name} '
            'SAFE=${v.safeToDeleteAt(now)}';
        _log.log(line);
        lines.add(line);
      } catch (e) {
        final line = '$name → ERROR: $e';
        _log.log(line);
        lines.add(line);
      }
    }
    _log.section('VERIFICATION SELF-TEST done');
    return lines;
  }

  /// Uploads a local file to Immich by path (used by the cleanup-page
  /// "Upload now" recovery). Returns the Immich asset id on success, else null.
  Future<String?> uploadPathToImmich(String localPath, String filename) async {
    final stat = await File(localPath).stat();
    final file = UploadFile(
      localPath: localPath,
      filename: filename,
      sizeBytes: stat.size,
      lastModifiedMs: stat.modified.millisecondsSinceEpoch,
    );
    final result = await _uploadToImmich(file);
    return result.isSuccess ? result.remoteAssetId : null;
  }

  /// Streams the whole-file SHA-512 of [path] (hex) — used to cross-check a
  /// staged upload against the source before an irreversible auto-delete.
  Future<String> _wholeFileSha512(String path) async {
    final sink = _DigestSink();
    final input = sha512.startChunkedConversion(sink);
    await for (final chunk in File(path).openRead()) {
      input.add(chunk);
    }
    input.close();
    return sink.value!.toString();
  }

  Future<UploadResult> _uploadToImmich(UploadFile file, [Completer<void>? cancelToken, String? overridePath]) async {
    // Read the BYTES from the local staged copy when we have one (batch item 4);
    // identity fields (deviceAssetId, filename) stay the ORIGINAL so Immich
    // dedups correctly regardless of where the bytes were read from.
    final f = File(overridePath ?? file.localPath);
    final fields = {
      'deviceAssetId': file.localPath,
      'deviceId': Store.get(StoreKey.deviceId),
      'fileCreatedAt': DateTime.fromMillisecondsSinceEpoch(file.lastModifiedMs).toUtc().toIso8601String(),
      'fileModifiedAt': DateTime.fromMillisecondsSinceEpoch(file.lastModifiedMs).toUtc().toIso8601String(),
      'isFavorite': 'false',
      'duration': '0',
    };
    return _immichUploadRepo.uploadFile(
      file: f,
      originalFileName: file.filename,
      fields: fields,
      cancelToken: cancelToken,
      onProgress: (bytes, total) {
        if (total > 0) {
          file.uploadedBytes = bytes;
          _notify();
        }
      },
      logContext: 'copypartyImport[${file.filename}]',
    );
  }

  void _notify() {
    // Force a state update so the UI rebuilds. Reconstruct ALL fields (a bare
    // copyWith would clear errorMessage; an omission would drop scannedFiles /
    // selectedPaths) so per-tick rebuilds don't lose the selection used to
    // filter the progress list.
    state = ImportSessionState(
      step: state.step,
      directoryPath: state.directoryPath,
      uploadSets: state.uploadSets,
      completedFiles: state.completedFiles,
      totalFiles: state.totalFiles,
      scannedFiles: state.scannedFiles,
      errorMessage: state.errorMessage,
      selectedPaths: state.selectedPaths,
      cancelled: state.cancelled,
      paused: state.paused,
    );
  }
}

final importSessionProvider = StateNotifierProvider<ImportSessionNotifier, ImportSessionState>(
  (ref) => ImportSessionNotifier(
    ref.watch(copypartyUploaderProvider),
    ref.watch(copypartyReceiptRepositoryProvider),
    ref.watch(uploadRepositoryProvider),
    ref,
  ),
);

String _stripSlashes(String s) => s.replaceAll(RegExp(r'^/+|/+$'), '');

/// Recreates the picked folder's structure beneath the configured [base]
/// upload path (FB9). The picked folder's OWN name becomes the top-level
/// destination subfolder, and any nested subfolders are preserved under it.
/// e.g. base="/uploads", rootDir="/sd/Camera 01":
///   file="/sd/Camera 01/clip.mp4"          → "/uploads/Camera 01"
///   file="/sd/Camera 01/DCIM/100/clip.mp4" → "/uploads/Camera 01/DCIM/100"
/// A file that somehow sits outside the picked root falls back to [base].
String mirroredUploadPath(String base, String? rootDir, String fileLocalPath) {
  final cleanBase = base.replaceAll(RegExp(r'/+$'), '');
  if (rootDir == null) {
    return base;
  }
  final root = rootDir.replaceAll(RegExp(r'/+$'), '');
  final rootName = root.split('/').where((s) => s.isNotEmpty).isEmpty
      ? ''
      : root.split('/').where((s) => s.isNotEmpty).last;
  if (rootName.isEmpty) {
    return base;
  }

  final slash = fileLocalPath.lastIndexOf('/');
  final fileDir = slash < 0 ? '' : fileLocalPath.substring(0, slash);

  String rel;
  if (fileDir == root) {
    rel = '';
  } else if (fileDir.startsWith('$root/')) {
    rel = fileDir.substring(root.length).replaceAll(RegExp(r'^/+|/+$'), '');
  } else {
    return base; // file outside the picked root — don't guess
  }
  final tail = rel.isEmpty ? rootName : '$rootName/$rel';
  return '$cleanBase/$tail';
}
