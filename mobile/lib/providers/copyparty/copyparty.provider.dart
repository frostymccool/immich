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
import 'package:immich_mobile/services/copyparty/copyparty_logger.dart';
import 'package:immich_mobile/services/copyparty/copyparty_staging.service.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

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

  /// Prefetch of the NEXT file's local staged copy, kicked off while the current
  /// file uploads (decision: stage one ahead). Keyed by source path so the loop
  /// can await it if it turns out to be the file it picks next, or discard it if
  /// the queue changed. (batch: item 4)
  String? _prefetchPath;
  Future<HashedFile?>? _prefetchFuture;

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
      final pairer = CopypartyFilePairer(triggerExtensions: config.triggerExtensions);
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
        {
          // FB9: when "create folders" is on, mirror the file's subfolder beneath
          // the upload path, rooted at the set's OWN picked folder (so added
          // folders mirror correctly, not against the first pick's root).
          final uploadPath = createFolders
              ? mirroredUploadPath(config.uploadPath, set.rootPath ?? state.directoryPath, file.localPath)
              : config.uploadPath;
          int? receiptId;
          final fileSizeBytes = file.sizeBytes;
          // Stage the file to local phone storage first (copy + hash in one USB
          // read pass) when enabled — then upload from the fast local copy. Null
          // means "read directly from the source" (staging off, or it failed /
          // ran out of space → automatic fallback). (batch: item 4)
          HashedFile? staged;
          try {
            if (useStaging && (file.needsCopyparty || file.needsImmich)) {
              staged = await _acquireStaged(file, cancelToken);
            }
            // Copy phase is over for THIS file — clear the flag so the card
            // stops showing "Copying" regardless of which backend runs next.
            file.staging = false;
            final readPath = staged?.path ?? file.localPath;

            // Now that the (foreground) copy of THIS file is done, start copying
            // the NEXT file ahead in the background while this one uploads over
            // the network — the USB is otherwise idle during the transfer.
            if (useStaging) {
              _maybePrefetchNext(cancelToken, file.localPath);
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
                  cancelToken: cancelToken,
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
                  cancelToken: cancelToken,
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

              final result = await _uploadToImmich(file, cancelToken, staged?.path);
              if (result.isSuccess) {
                file.immichAssetId = result.remoteAssetId;
                if (receiptId != null && result.remoteAssetId != null) {
                  await _receiptRepo.markImmichUploaded(receiptId, result.remoteAssetId!);
                }
              } else if (result.isCancelled || cancelToken.isCompleted) {
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
            }
            state = state.copyWith(completedFiles: state.completedFiles + 1);
          } on CopypartyCancelledException {
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
    } finally {
      // Teardown ALWAYS runs (even on an unexpected throw) so _uploadRunning and
      // the cancel token can't get stuck true → a wedged, unrestartable session.
      // Because _uploadRunning gated entry, this invocation is the sole owner of
      // the shared state here; no second loop can have started. (concurrency finding 1)
      final pendingPrefetch = _prefetchFuture;
      _prefetchPath = null;
      _prefetchFuture = null;
      if (pendingPrefetch != null) {
        // On cancel the prefetch holds the now-completed token, so it aborts
        // within a chunk and self-deletes its partial; awaiting it guarantees no
        // detached writer survives into a later resume. (review finding 2)
        try {
          await pendingPrefetch;
        } catch (_) {}
      }
      _uploadCancelToken = null;
      _uploadRunning = false;
      _log.log(
        'IMPORT SESSION ${cancelled ? 'cancelled' : 'complete'}: '
        '${state.completedFiles}/${state.totalFiles} files done',
      );
      // Only advance to the completion screen if we're still uploading — a
      // concurrent reset() (e.g. the user left the page) must not be clobbered.
      if (state.step == ImportSessionStep.uploading) {
        state = state.copyWith(step: ImportSessionStep.complete, cancelled: cancelled);
      }
    }
  }

  /// Returns a local staged [HashedFile] for [file], or null to upload directly
  /// from the source (staging off / failed / out of space → fallback). Order:
  /// consume a matching prefetch → reuse an existing valid staged copy (resume)
  /// → stage now with on-card progress. (batch: item 4)
  Future<HashedFile?> _acquireStaged(UploadFile file, Completer<void> cancelToken) async {
    // If a prefetch for this file is in flight, await it so its staged copy +
    // marker are fully written — but do NOT trust its result directly. We fall
    // through to findValidStaged, which RE-VALIDATES the staged copy against the
    // CURRENT source (size + mtime). The prefetch copied the bytes minutes ago
    // (during the previous file's upload); the source could have changed since,
    // and only findValidStaged's guard catches that. (review finding 1)
    if (_prefetchPath == file.localPath && _prefetchFuture != null) {
      final fut = _prefetchFuture!;
      _prefetchPath = null;
      _prefetchFuture = null;
      try {
        await fut;
      } catch (_) {}
    }
    try {
      final existing = await _staging.findValidStaged(file.localPath);
      if (existing != null) {
        return existing;
      }
    } catch (_) {}
    return _stageNow(file, cancelToken);
  }

  Future<HashedFile?> _stageNow(UploadFile file, Completer<void> cancelToken) async {
    try {
      file.staging = true;
      file.status = UploadFileStatus.hashing;
      file.uploadedBytes = 0;
      _notify();
      return await _staging.stage(
        file.localPath,
        cancelToken: cancelToken,
        onProgress: (done, total) {
          file.staging = true;
          file.status = UploadFileStatus.hashing;
          file.uploadedBytes = done;
          _notify();
        },
      );
    } on CopypartyCancelledException {
      rethrow;
    } catch (e) {
      // Out of space / IO error → automatic fallback to reading from source.
      _log.log('staging failed for ${file.filename}: $e — reading direct from source');
      return null;
    } finally {
      file.staging = false;
    }
  }

  /// Starts copying the next queued file to local storage in the background
  /// (decision: stage one ahead), so its copy overlaps the current file's
  /// network upload. At most one prefetch runs at a time. (batch: item 4)
  void _maybePrefetchNext(Completer<void> cancelToken, String excludePath) {
    if (_prefetchFuture != null || cancelToken.isCompleted) {
      return;
    }
    final config = _ref.read(appConfigProvider).copyparty;
    final sel = state.selectedPaths;
    final candidates = <UploadFile>[];
    final owner = <UploadFile, UploadSet>{};
    for (final s in state.uploadSets) {
      for (final f in s.files) {
        if (f.localPath == excludePath || f.status != UploadFileStatus.pending) {
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
    _prefetchPath = next.localPath;
    _prefetchFuture = () async {
      try {
        final existing = await _staging.findValidStaged(next.localPath);
        if (existing != null) {
          return existing;
        }
        return await _staging.stage(
          next.localPath,
          cancelToken: cancelToken,
          // Surface the copy-ahead so the file being prefetched shows
          // "Copying to phone N%" while the current file uploads — otherwise a
          // large file being staged looks frozen at 0%. We deliberately do NOT
          // touch `status` (it must stay `pending` so the loop still picks it);
          // only the transient `staging` flag drives the card. (feedback)
          onProgress: (done, total) {
            next.staging = true;
            next.uploadedBytes = done;
            _notify();
          },
        );
      } catch (_) {
        next.staging = false;
        next.uploadedBytes = 0;
        _notify();
        return null;
      }
    }();
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
    final pairer = CopypartyFilePairer(triggerExtensions: config.triggerExtensions);
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
    }
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
