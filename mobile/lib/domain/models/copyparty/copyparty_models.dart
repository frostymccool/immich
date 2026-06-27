import 'package:uuid/uuid.dart';

enum UploadSetStatus { pending, hashing, uploading, verified, failed, deleted }

enum UploadFileStatus { pending, hashing, handshaking, uploading, confirmed, immichUploading, receiptWritten, failed }

/// Where the file should be sent during import.
enum UploadDestination { copypartyOnly, immichNative, both }

class UploadFile {
  final String localPath;
  final String filename;
  final int sizeBytes;
  final int lastModifiedMs;
  final bool isTriggerFile;
  final bool isNativeImmichFile;
  String? sha512;
  String? wark;
  bool receiptWritten;
  bool dbRecordWritten;
  UploadFileStatus status;
  String? errorMessage;
  int uploadedBytes;
  UploadDestination destination;
  String? immichAssetId;
  CopypartyReceipt? existingReceipt;

  UploadFile({
    required this.localPath,
    required this.filename,
    required this.sizeBytes,
    required this.lastModifiedMs,
    this.isTriggerFile = false,
    this.isNativeImmichFile = false,
    this.sha512,
    this.wark,
    this.receiptWritten = false,
    this.dbRecordWritten = false,
    this.status = UploadFileStatus.pending,
    this.errorMessage,
    this.uploadedBytes = 0,
    UploadDestination? destination,
    this.immichAssetId,
    this.existingReceipt,
  }) : destination = destination ??
           (isNativeImmichFile ? UploadDestination.both : UploadDestination.copypartyOnly);

  double get progress => sizeBytes > 0 ? uploadedBytes / sizeBytes : 0.0;

  bool get safeToDelete =>
      sha512 != null &&
      dbRecordWritten &&
      (!needsImmich || immichAssetId != null);

  bool get needsCopyparty =>
      destination == UploadDestination.copypartyOnly || destination == UploadDestination.both;

  bool get needsImmich =>
      destination == UploadDestination.immichNative || destination == UploadDestination.both;

  bool get alreadyUploaded => existingReceipt != null;
  bool get alreadyUploadedToImmich => existingReceipt?.immichAssetId != null;
  bool get copypartyConfirmed => sha512 != null && wark != null;
  bool get immichConfirmed => immichAssetId != null;
}

class UploadSet {
  final String id;
  final List<UploadFile> files;
  final String? directoryPath;
  UploadSetStatus status;

  UploadSet({
    String? id,
    required this.files,
    this.directoryPath,
    this.status = UploadSetStatus.pending,
  }) : id = id ?? const Uuid().v4();

  int get totalBytes => files.fold(0, (sum, f) => sum + f.sizeBytes);

  int get uploadedBytes => files.fold(0, (sum, f) => sum + f.uploadedBytes);

  double get progress => totalBytes > 0 ? uploadedBytes / totalBytes : 0.0;

  String get displayName {
    final triggerFile = files.firstWhere(
      (f) => f.isTriggerFile,
      orElse: () => files.first,
    );
    return triggerFile.filename;
  }

  bool get safeToDelete => files.every((f) => f.safeToDelete);
}

class HashedFile {
  final String path;
  final String filename;
  final int totalBytes;
  final int chunkSizeBytes;
  final List<String> chunkHashes;
  final String fileHash;
  final int lastModifiedMs;

  const HashedFile({
    required this.path,
    required this.filename,
    required this.totalBytes,
    required this.chunkSizeBytes,
    required this.chunkHashes,
    required this.fileHash,
    required this.lastModifiedMs,
  });
}

class HandshakeResult {
  final String wark;
  final List<int> neededChunks;
  final String purl;

  /// Chunk hashes the server said it still needs that did NOT match any of our
  /// locally-computed chunk hashes. A non-zero count means a protocol/hash
  /// mismatch — the upload must NOT be treated as confirmed when this is set.
  final List<String> unmatchedHashes;

  const HandshakeResult({
    required this.wark,
    required this.neededChunks,
    required this.purl,
    this.unmatchedHashes = const [],
  });

  /// True only when the server needs nothing AND every needed hash it ever
  /// reported was one we recognise. Silent hash mismatches never count as done.
  bool get fullyConfirmed => neededChunks.isEmpty && unmatchedHashes.isEmpty;

  bool get alreadyOnServer => fullyConfirmed;
}

class CopypartyReceipt {
  final int? id;
  final String filename;
  final String localPath;
  final int sizeBytes;
  final String sha512File;
  final String wark;
  final DateTime uploadTimestamp;
  final String copypartyUrl;
  final bool receiptFileWritten;
  final bool sourceDeleted;
  final bool uploadConfirmed;
  final String? immichAssetId;

  const CopypartyReceipt({
    this.id,
    required this.filename,
    required this.localPath,
    required this.sizeBytes,
    required this.sha512File,
    required this.wark,
    required this.uploadTimestamp,
    required this.copypartyUrl,
    this.receiptFileWritten = false,
    this.sourceDeleted = false,
    this.uploadConfirmed = false,
    this.immichAssetId,
  });

  CopypartyReceipt copyWith({
    bool? receiptFileWritten,
    bool? sourceDeleted,
    bool? uploadConfirmed,
    String? immichAssetId,
  }) => CopypartyReceipt(
    id: id,
    filename: filename,
    localPath: localPath,
    sizeBytes: sizeBytes,
    sha512File: sha512File,
    wark: wark,
    uploadTimestamp: uploadTimestamp,
    copypartyUrl: copypartyUrl,
    receiptFileWritten: receiptFileWritten ?? this.receiptFileWritten,
    sourceDeleted: sourceDeleted ?? this.sourceDeleted,
    uploadConfirmed: uploadConfirmed ?? this.uploadConfirmed,
    immichAssetId: immichAssetId ?? this.immichAssetId,
  );
}
