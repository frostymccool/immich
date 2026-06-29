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
  if (resp == null || resp.results.isEmpty) return null;
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
final copypartyLoggerProvider = Provider<CopypartyLogger>(
  (ref) => CopypartyLogger.instance,
);

final copypartyUploaderProvider = Provider<CopypartyUploaderService>(
  (ref) {
    final allowSelfSigned = ref.watch(
      appConfigProvider.select((c) => c.copyparty.allowSelfSignedCert),
    );
    http.Client client;
    if (allowSelfSigned) {
      final httpClient = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      client = IOClient(httpClient);
    } else {
      client = http.Client();
    }
    final service = CopypartyUploaderService(
      client: client,
      logger: ref.watch(copypartyLoggerProvider),
    );
    ref.onDispose(service.dispose);
    return service;
  },
);

final copypartyReceiptRepositoryProvider = Provider<CopypartyReceiptRepository>(
  (ref) => CopypartyReceiptRepository(ref.watch(driftProvider)),
);

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

final pendingCleanupProvider = FutureProvider<List<CopypartyReceipt>>((ref) {
  return ref.watch(copypartyReceiptRepositoryProvider).getUndeleted();
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

  const ImportSessionState({
    this.step = ImportSessionStep.idle,
    this.directoryPath,
    this.uploadSets = const [],
    this.completedFiles = 0,
    this.totalFiles = 0,
    this.scannedFiles = 0,
    this.errorMessage,
  });

  ImportSessionState copyWith({
    ImportSessionStep? step,
    String? directoryPath,
    List<UploadSet>? uploadSets,
    int? completedFiles,
    int? totalFiles,
    int? scannedFiles,
    String? errorMessage,
  }) => ImportSessionState(
    step: step ?? this.step,
    directoryPath: directoryPath ?? this.directoryPath,
    uploadSets: uploadSets ?? this.uploadSets,
    completedFiles: completedFiles ?? this.completedFiles,
    totalFiles: totalFiles ?? this.totalFiles,
    scannedFiles: scannedFiles ?? this.scannedFiles,
    errorMessage: errorMessage,
  );

  int get totalBytes => uploadSets.fold(0, (s, u) => s + u.totalBytes);
}

class ImportSessionNotifier extends StateNotifier<ImportSessionState> {
  final CopypartyUploaderService _uploader;
  final CopypartyReceiptRepository _receiptRepo;
  final UploadRepository _immichUploadRepo;
  final Ref _ref;

  CopypartyLogger get _log => _ref.read(copypartyLoggerProvider);

  ImportSessionNotifier(this._uploader, this._receiptRepo, this._immichUploadRepo, this._ref)
      : super(const ImportSessionState());

  void reset() => state = const ImportSessionState();

  Future<void> scan(String directoryPath) async {
    state = state.copyWith(
      step: ImportSessionStep.scanning,
      directoryPath: directoryPath,
      scannedFiles: 0,
    );

    try {
      final config = _ref.read(appConfigProvider).copyparty;
      final pairer = CopypartyFilePairer(
        triggerExtensions: config.triggerExtensions,
      );
      final sets = await pairer.scanDirectory(
        directoryPath,
        onFileFound: (count) => state = state.copyWith(scannedFiles: count),
      );
      for (final set in sets) {
        for (final file in set.files) {
          file.existingReceipt = await _receiptRepo.findByLocalPath(file.localPath);
        }
      }

      // LIVE server verification (Issue 3): trust the server, not receipts.
      // One folder listing covers every file (all upload to config.uploadPath).
      // Name/size/partial only — the content hash stays unchecked until upload.
      if (config.hostUrl.isNotEmpty) {
        try {
          final password = await _ref.read(copypartyPasswordProvider.future);
          final sizes = await _uploader.listUploadFolder(
            config.hostUrl,
            config.uploadPath,
            password,
          );
          for (final set in sets) {
            for (final file in set.files) {
              file.verification = CopypartyUploaderService.verificationFromListing(
                sizes,
                file.filename,
                file.sizeBytes,
                immichApplicable: file.needsImmich,
              );
            }
          }
        } catch (e) {
          _log.log('scan: live verification skipped: $e');
        }
      }

      state = state.copyWith(
        step: ImportSessionStep.options,
        uploadSets: sets,
        totalFiles: sets.fold<int>(0, (s, u) => s + u.files.length),
      );
    } catch (e) {
      state = state.copyWith(
        step: ImportSessionStep.idle,
        errorMessage: 'Scan failed: $e',
      );
    }
  }

  Future<void> startUpload({Set<String>? selectedFilePaths}) async {
    final config = _ref.read(appConfigProvider).copyparty;
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

    final effectiveTotal = selectedFilePaths != null
        ? selectedFilePaths.length
        : state.totalFiles;

    state = state.copyWith(
      step: ImportSessionStep.uploading,
      completedFiles: 0,
      totalFiles: effectiveTotal,
    );

    for (final set in state.uploadSets) {
      for (final file in set.files) {
        if (selectedFilePaths != null && !selectedFilePaths.contains(file.localPath)) {
          continue;
        }
        if (file.status == UploadFileStatus.failed) {
          continue;
        }
        int? receiptId;
        try {
          // ---- Copyparty upload ----
          if (file.needsCopyparty) {
            file.status = UploadFileStatus.hashing;
            _notify();

            final fileSizeBytes = file.sizeBytes;
            final (hashed, confirmed, alreadyOnServer) = await _uploader.uploadFile(
              file.localPath,
              config.hostUrl,
              config.uploadPath,
              password,
              parallelism: config.parallelConnections,
              onHashProgress: (done, total) {
                if (total > 0) {
                  file.uploadedBytes = (done * 0.2).round();
                }
                _notify();
              },
              onUploadProgress: (done, total) {
                final chunkProgress = total > 0 ? done / total : 0.0;
                file.uploadedBytes = (fileSizeBytes * (0.2 + 0.8 * chunkProgress)).round();
                _notify();
              },
            );

            file.sha512 = hashed.fileHash;
            file.wark = confirmed.wark;
            file.uploadedBytes = file.sizeBytes;
            file.alreadyOnServer = alreadyOnServer;
            file.status = UploadFileStatus.confirmed;

            // Write DB receipt — upload_confirmed=true since uploadFile() only
            // returns successfully after the confirmation handshake passes.
            final uploadUrl =
                '${config.hostUrl.trimRight()}/${_stripSlashes(config.uploadPath)}/${file.filename}';
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

            if (config.writeReceipts) {
              final written = await _uploader.writeReceiptFile(
                hashed,
                confirmed.wark,
                config.hostUrl,
                config.uploadPath,
                packageInfo.version,
              );
              if (written) {
                file.receiptWritten = true;
                await _receiptRepo.markReceiptWritten(receiptId);
              }
            }

            if (config.autoDeleteAfterVerify && file.safeToDelete && !file.needsImmich) {
              try {
                await File(file.localPath).delete();
                await _receiptRepo.markSourceDeleted(receiptId);
              } catch (_) {}
            }
          }

          // ---- Immich native upload ----
          if (file.needsImmich) {
            file.status = UploadFileStatus.immichUploading;
            file.uploadedBytes = 0;
            _notify();

            final result = await _uploadToImmich(file);
            if (result.isSuccess) {
              file.immichAssetId = result.remoteAssetId;
              if (receiptId != null && result.remoteAssetId != null) {
                await _receiptRepo.markImmichUploaded(receiptId, result.remoteAssetId!);
              }
            } else if (!result.isCancelled) {
              throw Exception(result.errorMessage ?? 'Immich upload failed');
            }
          }

          file.status = UploadFileStatus.receiptWritten;
          state = state.copyWith(completedFiles: state.completedFiles + 1);
        } catch (e) {
          file.status = UploadFileStatus.failed;
          file.errorMessage = e.toString();
          _log.log('!! FAILED ${file.filename}: $e');
          _notify();
        }
      }
    }

    _log.log('IMPORT SESSION complete: '
        '${state.completedFiles}/${state.totalFiles} files done');
    state = state.copyWith(step: ImportSessionStep.complete);
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
    _log.log('host=${config.hostUrl}  uploadPath=${config.uploadPath}  '
        'files=${filePaths.length}  stamp=$stamp');

    final tmp = await getTemporaryDirectory();
    final results = <UploadAttemptResult>[];

    Future<void> attempt(
      String path,
      String uploadPath,
      String label, {
      bool sequential = false,
    }) async {
      results.add(await _uploader.runInstrumentedUpload(
        filePath: path,
        hostUrl: config.hostUrl,
        uploadPath: uploadPath,
        password: password,
        label: label,
        parallelism: config.parallelConnections,
        sequential: sequential,
      ));
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
        await newc.writeAsBytes(
          utf8.encode('\n#immich-selftest-$stamp\n'),
          mode: FileMode.append,
        );
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
        await seqc.writeAsBytes(
          utf8.encode('\n#immich-selftest-SEQ-$stamp\n'),
          mode: FileMode.append,
        );
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
      final fileUrl =
          '${config.hostUrl.trimRight()}/${_stripSlashes(config.uploadPath)}/$name';
      try {
        final size = await File(path).length();
        var v = CopypartyUploaderService.verificationFromListing(sizes, name, size);
        v = await _uploader.verifyHash(
          fileUrl: fileUrl,
          localPath: path,
          password: password,
          base: v,
        );
        final applicable = CopypartyFilePairer.isNativeImmichFilename(name);
        VerifyState immich = VerifyState.unknown;
        if (applicable) {
          try {
            immich = (await immichAssetIdByChecksum(api, path)) != null
                ? VerifyState.yes
                : VerifyState.no;
          } catch (_) {}
        }
        v = v.copyWith(immich: immich, immichApplicable: applicable);
        final line = '$name → name=${v.filenamePresent.name} '
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

  Future<UploadResult> _uploadToImmich(UploadFile file) async {
    final f = File(file.localPath);
    final fields = {
      'deviceAssetId': file.localPath,
      'deviceId': Store.get(StoreKey.deviceId),
      'fileCreatedAt': DateTime.fromMillisecondsSinceEpoch(file.lastModifiedMs)
          .toUtc()
          .toIso8601String(),
      'fileModifiedAt': DateTime.fromMillisecondsSinceEpoch(file.lastModifiedMs)
          .toUtc()
          .toIso8601String(),
      'isFavorite': 'false',
      'duration': '0',
    };
    return _immichUploadRepo.uploadFile(
      file: f,
      originalFileName: file.filename,
      fields: fields,
      cancelToken: null,
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
    // Force a state update so the UI rebuilds
    state = ImportSessionState(
      step: state.step,
      directoryPath: state.directoryPath,
      uploadSets: state.uploadSets,
      completedFiles: state.completedFiles,
      totalFiles: state.totalFiles,
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
