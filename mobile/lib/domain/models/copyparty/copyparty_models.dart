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
  // Live server verification (name/size/partial) computed at scan time; the
  // hash axis stays unchecked until upload or an explicit verify. (Issue 3)
  ServerFileVerification? verification;
  // The copyparty FOLDER URL the file was actually uploaded to. With FB9
  // "Recreate folder structure" this is the mirrored subfolder, not the base
  // upload path — the completion-screen delete must re-verify against THIS,
  // not config.uploadPath, or every mirrored upload looks "not present".
  String? uploadFolderUrl;
  // Network-transfer timing (excludes hashing). Set in the upload loop when the
  // first transfer tick lands and frozen when the file finishes, so the "total ·
  // elapsed · avg" line is stable and survives widget recycling — it used to
  // live in ephemeral card state and vanished when the list scrolled. (Batch: item 2)
  int? transferStartMs;
  int? transferEndMs;
  // Transient (not persisted): true while the file is being COPIED to local
  // phone storage before hashing/upload, so the card can show "Copying" instead
  // of "Hashing". (batch: item 4)
  bool staging;
  // Transient: the copy-ahead finished and the file is fully staged (copied AND
  // hashed — the hash is computed during the copy) and just waiting for its
  // upload turn. Shown as "Copied", not a stuck "Copying 100%". (feedback)
  bool stagedReady;

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
    this.verification,
    this.staging = false,
    this.stagedReady = false,
  }) : destination = destination ?? (isNativeImmichFile ? UploadDestination.both : UploadDestination.copypartyOnly);

  double get progress => sizeBytes > 0 ? uploadedBytes / sizeBytes : 0.0;

  bool get safeToDelete => sha512 != null && dbRecordWritten && (!needsImmich || immichAssetId != null);

  bool get needsCopyparty => destination == UploadDestination.copypartyOnly || destination == UploadDestination.both;

  bool get needsImmich => destination == UploadDestination.immichNative || destination == UploadDestination.both;

  bool get alreadyUploaded => existingReceipt != null;
  bool get alreadyUploadedToImmich => existingReceipt?.immichAssetId != null;
  bool get copypartyConfirmed => sha512 != null && wark != null;
  bool get immichConfirmed => immichAssetId != null;

  /// Frozen network-transfer duration (null until the file finishes transferring
  /// or if it was already on the server and never transferred).
  Duration? get transferElapsed => (transferStartMs != null && transferEndMs != null)
      ? Duration(milliseconds: transferEndMs! - transferStartMs!)
      : null;
}

class UploadSet {
  final String id;
  final List<UploadFile> files;
  final String? directoryPath;
  // The picked root folder this set was scanned from — used as the FB9 mirror
  // root so folders added mid-run (from a different pick) mirror correctly.
  String? rootPath;
  UploadSetStatus status;

  UploadSet({String? id, required this.files, this.directoryPath, this.rootPath, this.status = UploadSetStatus.pending})
    : id = id ?? const Uuid().v4();

  int get totalBytes => files.fold(0, (sum, f) => sum + f.sizeBytes);

  int get uploadedBytes => files.fold(0, (sum, f) => sum + f.uploadedBytes);

  double get progress => totalBytes > 0 ? uploadedBytes / totalBytes : 0.0;

  String get displayName {
    final triggerFile = files.firstWhere((f) => f.isTriggerFile, orElse: () => files.first);
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

  /// Immich presence (by checksum). `unknown` = not checked yet.
  final VerifyState immich;

  /// Whether Immich applies to this file at all. false = copyparty-only file
  /// (Immich shown as "n/a", and it never blocks deletion).
  final bool immichApplicable;

  /// Set when the listing/verification call itself failed (network, auth…).
  final String? error;

  const ServerFileVerification({
    this.filenamePresent = VerifyState.unknown,
    this.sizeMatches = VerifyState.unknown,
    this.partialExists = VerifyState.unknown,
    this.hashValidatedAt,
    this.immich = VerifyState.unknown,
    this.immichApplicable = false,
    this.error,
  });

  /// A hash validation counts as fresh for 10 minutes — long enough that a
  /// slow sequential "Verify all" over many large clips doesn't expire the
  /// first files before the user taps delete, but still time-bounded so a
  /// long-stale verification isn't trusted.
  bool hashFreshAt(DateTime now) =>
      hashValidatedAt != null && now.difference(hashValidatedAt!) < const Duration(minutes: 10);

  /// Copyparty side is fully proven: present, same size, no lingering partial,
  /// and a fresh hash validation.
  bool copypartyVerifiedAt(DateTime now) =>
      filenamePresent == VerifyState.yes &&
      sizeMatches == VerifyState.yes &&
      partialExists != VerifyState.yes &&
      hashFreshAt(now);

  /// Immich axis is satisfied: either it doesn't apply (CP-only) or the file
  /// is confirmed present in Immich.
  bool get immichOk => !immichApplicable || immich == VerifyState.yes;

  /// Safe to delete the local original: copyparty hash-verified AND Immich-ok.
  bool safeToDeleteAt(DateTime now) => copypartyVerifiedAt(now) && immichOk;

  /// Back-compat alias used by the cleanup picker default-selection logic.
  bool stronglyVerifiedAt(DateTime now) => safeToDeleteAt(now);

  /// `error` and `hashValidatedAt` are null-coalesced (a copyWith that omits
  /// them PRESERVES the existing value) so a partial update can never silently
  /// erase an offline/auth error or a fresh hash. To CLEAR them, pass the
  /// explicit `clearError` / `clearHash` flags — used on every failed/non-
  /// success verify so a file that can no longer be proven drops out of "safe".
  ServerFileVerification copyWith({
    VerifyState? filenamePresent,
    VerifyState? sizeMatches,
    VerifyState? partialExists,
    DateTime? hashValidatedAt,
    bool clearHash = false,
    VerifyState? immich,
    bool? immichApplicable,
    String? error,
    bool clearError = false,
  }) => ServerFileVerification(
    filenamePresent: filenamePresent ?? this.filenamePresent,
    sizeMatches: sizeMatches ?? this.sizeMatches,
    partialExists: partialExists ?? this.partialExists,
    hashValidatedAt: clearHash ? null : (hashValidatedAt ?? this.hashValidatedAt),
    immich: immich ?? this.immich,
    immichApplicable: immichApplicable ?? this.immichApplicable,
    error: clearError ? null : (error ?? this.error),
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
