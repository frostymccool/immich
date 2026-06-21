import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/infrastructure/repositories/copyparty_receipt.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';
import 'package:immich_mobile/services/copyparty/copyparty_file_pairer.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _copypartyPasswordKey = 'copyparty_password';

// ---------------------------------------------------------------------------
// Service providers
// ---------------------------------------------------------------------------

final copypartyUploaderProvider = Provider<CopypartyUploaderService>(
  (ref) {
    final service = CopypartyUploaderService();
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
  final String? errorMessage;

  const ImportSessionState({
    this.step = ImportSessionStep.idle,
    this.directoryPath,
    this.uploadSets = const [],
    this.completedFiles = 0,
    this.totalFiles = 0,
    this.errorMessage,
  });

  ImportSessionState copyWith({
    ImportSessionStep? step,
    String? directoryPath,
    List<UploadSet>? uploadSets,
    int? completedFiles,
    int? totalFiles,
    String? errorMessage,
  }) => ImportSessionState(
    step: step ?? this.step,
    directoryPath: directoryPath ?? this.directoryPath,
    uploadSets: uploadSets ?? this.uploadSets,
    completedFiles: completedFiles ?? this.completedFiles,
    totalFiles: totalFiles ?? this.totalFiles,
    errorMessage: errorMessage,
  );

  int get totalBytes => uploadSets.fold(0, (s, u) => s + u.totalBytes);
}

class ImportSessionNotifier extends StateNotifier<ImportSessionState> {
  final CopypartyUploaderService _uploader;
  final CopypartyReceiptRepository _receiptRepo;
  final Ref _ref;

  ImportSessionNotifier(this._uploader, this._receiptRepo, this._ref)
      : super(const ImportSessionState());

  void reset() => state = const ImportSessionState();

  Future<void> scan(String directoryPath) async {
    state = state.copyWith(step: ImportSessionStep.scanning, directoryPath: directoryPath);

    try {
      final config = _ref.read(appConfigProvider).copyparty;
      final pairer = CopypartyFilePairer(
        triggerExtensions: config.triggerExtensions,
      );
      final sets = await pairer.scanDirectory(directoryPath);
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

  Future<void> startUpload() async {
    final config = _ref.read(appConfigProvider).copyparty;
    final password = await _ref.read(copypartyPasswordProvider.future);
    final packageInfo = await PackageInfo.fromPlatform();

    state = state.copyWith(step: ImportSessionStep.uploading, completedFiles: 0);

    for (final set in state.uploadSets) {
      for (final file in set.files) {
        if (file.status == UploadFileStatus.failed) continue;
        try {
          file.status = UploadFileStatus.hashing;
          _notify();

          final fileSizeBytes = file.sizeBytes;
          final (hashed, confirmed) = await _uploader.uploadFile(
            file.localPath,
            config.hostUrl,
            config.uploadPath,
            password,
            parallelism: config.parallelConnections,
            onHashProgress: (done, total) {
              if (total > 0) file.uploadedBytes = (done * 0.2).round();
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
          file.status = UploadFileStatus.confirmed;

          // Write DB receipt
          final uploadUrl =
              '${config.hostUrl.trimRight()}/${_stripSlashes(config.uploadPath)}/${file.filename}';
          final receiptId = await _receiptRepo.insert(
            CopypartyReceipt(
              filename: file.filename,
              localPath: file.localPath,
              sizeBytes: file.sizeBytes,
              sha512File: hashed.fileHash,
              wark: confirmed.wark,
              uploadTimestamp: DateTime.now().toUtc(),
              copypartyUrl: uploadUrl,
            ),
          );
          file.dbRecordWritten = true;

          // Write .cpreceipt sidecar file
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

          file.status = UploadFileStatus.receiptWritten;

          // Auto-delete if configured and safe
          if (config.autoDeleteAfterVerify && file.safeToDelete) {
            try {
              await File(file.localPath).delete();
              await _receiptRepo.markSourceDeleted(receiptId);
            } catch (_) {
              // Deletion failed — leave the receipt in place for later
            }
          }

          state = state.copyWith(completedFiles: state.completedFiles + 1);
        } catch (e) {
          file.status = UploadFileStatus.failed;
          file.errorMessage = e.toString();
          _notify();
        }
      }
    }

    state = state.copyWith(step: ImportSessionStep.complete);
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
    ref,
  ),
);

String _stripSlashes(String s) => s.replaceAll(RegExp(r'^/+|/+$'), '');
