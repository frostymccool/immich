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
  // True when the upload was skipped because the content was already on the
  // server (hash matched at handshake) — surfaced as "already on server".
  bool alreadyOnServer;

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
    this.alreadyOnServer = false,
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

/// Result of one instrumented upload attempt in the self-test suite.
class UploadAttemptResult {
  final String label; // e.g. "newcontent:LIV…lrv"
  final String sentName; // the name actually sent in the handshake
  final String uploadPath;
  final String? wark; // server-computed file identifier (null on early error)
  final int totalChunks;
  final int initialNeeded; // chunks the server wanted BEFORE we uploaded
  final int uploadedChunks; // chunks we POSTed this attempt
  final int finalNeeded; // chunks the server STILL wanted after upload+confirm
  final bool success; // confirm reported nothing needed and all hashes matched
  final String? error;

  const UploadAttemptResult({
    required this.label,
    required this.sentName,
    required this.uploadPath,
    required this.wark,
    required this.totalChunks,
    required this.initialNeeded,
    required this.uploadedChunks,
    required this.finalNeeded,
    required this.success,
    this.error,
  });

  String get warkShort => wark == null ? '—' : '${wark!.substring(0, wark!.length.clamp(0, 8))}…';

  String get summaryLine {
    if (error != null) {
      return '$label → ERROR: ${error!.split('\n').first}';
    }
    return '$label → wark=$warkShort  '
        'init ${initialNeeded == -1 ? '?' : '$initialNeeded'}/$totalChunks  '
        'sent $uploadedChunks  '
        'final $finalNeeded/$totalChunks  '
        '${success ? 'PASS ✓' : 'FAIL ✗'}';
  }
}

/// Tri-state for a single piece of server-side evidence.
enum VerifyState { unknown, yes, no }

/// Independent evidence signals about whether a file is really, completely and
/// correctly on the copyparty server. Replaces the old single binary
/// "copyparty confirmed" assumption — each signal is shown to the user so a
/// delete decision is based on real, current server state, not a stored flag.
class ServerFileVerification {
  /// A file with the expected name exists in the target folder.
  final VerifyState filenamePresent;

  /// The server file's size equals the local file's size.
  final VerifyState sizeMatches;

  /// An incomplete/partial upload for this file exists on the server.
  /// `yes` here is a RED flag (upload never finished).
  final VerifyState partialExists;

  /// When the content hash was last positively validated against the server
  /// (via an up2k handshake that needed zero chunks). Null = never validated
  /// this session.
  final DateTime? hashValidatedAt;

  /// Set when the listing/verification call itself failed (network, auth…).
  final String? error;

  const ServerFileVerification({
    this.filenamePresent = VerifyState.unknown,
    this.sizeMatches = VerifyState.unknown,
    this.partialExists = VerifyState.unknown,
    this.hashValidatedAt,
    this.error,
  });

  /// A hash validation counts as fresh for 2 minutes (it can go stale if the
  /// local file changes, so it is deliberately time-bounded).
  bool hashFreshAt(DateTime now) =>
      hashValidatedAt != null &&
      now.difference(hashValidatedAt!) < const Duration(minutes: 2);

  /// Strong enough to safely delete the local original: present, same size,
  /// no lingering partial, and a fresh hash validation.
  bool stronglyVerifiedAt(DateTime now) =>
      filenamePresent == VerifyState.yes &&
      sizeMatches == VerifyState.yes &&
      partialExists != VerifyState.yes &&
      hashFreshAt(now);

  ServerFileVerification copyWith({
    VerifyState? filenamePresent,
    VerifyState? sizeMatches,
    VerifyState? partialExists,
    DateTime? hashValidatedAt,
    String? error,
  }) =>
      ServerFileVerification(
        filenamePresent: filenamePresent ?? this.filenamePresent,
        sizeMatches: sizeMatches ?? this.sizeMatches,
        partialExists: partialExists ?? this.partialExists,
        hashValidatedAt: hashValidatedAt ?? this.hashValidatedAt,
        error: error,
      );
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
