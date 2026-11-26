import 'dart:io';

import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/infrastructure/repositories/copyparty_receipt.repository.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';

/// Where the hashes for a verify came from.
enum VerifyHashSource {
  /// Saved at upload and confirmed by an independent read; the card was not read now.
  saved,

  /// The original on the card was read once now (and, when it matched the upload, its hashes were saved).
  cardRead,

  /// The card file is not there: the phone's cached copy (what was uploaded) was read.
  cachedCopy,
}

class VerifyHashes {
  final HashedFile hashed;
  final VerifyHashSource source;

  /// False when the card file was read now and does NOT match what was uploaded.
  final bool matchesUpload;

  const VerifyHashes(this.hashed, this.source, {this.matchesUpload = true});
}

/// Verifying an upload without re-reading the memory card every time.
///
/// copyparty and Immich never need the phone to read their copies: a handshake with the chunk ids makes
/// copyparty check its own copy, and Immich is asked by checksum. What costs time is producing those hashes
/// from the original. They are made once, in the read that uploads the file, and saved with the receipt.
///
/// They are trusted for the card file only when (1) a SECOND, independent read of the original matched the
/// upload (the check before an auto-delete, or the first Verify, which saves them), so a bad first read cannot
/// lead to deleting a good original, and (2) the card file still has the same size and modification time.
/// Otherwise the original is read once, producing the chunk ids and the Immich checksum together.
class SavedHashVerifier {
  final CopypartyUploaderService uploader;
  final CopypartyReceiptRepository repo;
  final Future<String?> Function(String sourcePath) stagedCopyPath;
  final void Function(String)? log;

  const SavedHashVerifier({required this.uploader, required this.repo, required this.stagedCopyPath, this.log});

  /// The saved hashes when they still describe [stat]'s file, else null.
  static HashedFile? savedFor(CopypartyReceipt r, FileStat stat) {
    final chunks = r.chunkHashes;
    final chunkSize = r.chunkSizeBytes;
    final mtime = r.sourceMtimeMs;
    if (!r.sourceChecked || chunks == null || chunks.isEmpty || chunkSize == null || mtime == null) {
      return null;
    }
    if (stat.type == FileSystemEntityType.notFound ||
        stat.size != r.sizeBytes ||
        stat.modified.millisecondsSinceEpoch != mtime) {
      return null;
    }
    return HashedFile(
      path: r.localPath,
      filename: r.filename,
      totalBytes: r.sizeBytes,
      chunkSizeBytes: chunkSize,
      chunkHashes: chunks,
      fileHash: r.sha512File,
      lastModifiedMs: mtime,
      sha1Base64: r.sha1Base64,
    );
  }

  Future<VerifyHashes> hashesFor(CopypartyReceipt r, {void Function(int done, int total)? onProgress}) async {
    final name = r.filename;
    final stat = FileStat.statSync(r.localPath);
    if (stat.type != FileSystemEntityType.notFound) {
      final saved = savedFor(r, stat);
      if (saved != null) {
        log?.call('verify $name: saved hashes, card not re-read');
        return VerifyHashes(saved, VerifyHashSource.saved);
      }
      // One read of the original gives the chunk ids, the whole-file hash and the Immich checksum together.
      final read = await uploader.hashFile(r.localPath, onProgress: onProgress);
      final matches = read.fileHash == r.sha512File;
      if (matches && r.id != null) {
        try {
          await repo.saveCheckedHashes(
            r.id!,
            chunkHashes: read.chunkHashes,
            chunkSizeBytes: read.chunkSizeBytes,
            sha1Base64: read.sha1Base64,
            sourceMtimeMs: stat.modified.millisecondsSinceEpoch,
          );
        } catch (e) {
          log?.call('verify $name: could not save the checked hashes ($e)');
        }
      }
      log?.call(
        matches
            ? 'verify $name: card read once, matches the upload; hashes saved for next time'
            : 'verify $name: card file does NOT match what was uploaded',
      );
      return VerifyHashes(read, VerifyHashSource.cardRead, matchesUpload: matches);
    }
    // The original is gone (card removed), so nothing on the card can be deleted: the saved hashes of what was
    // uploaded are enough to check the servers, else the phone's cached copy is read.
    final uploaded = r.chunkHashes != null && r.chunkSizeBytes != null
        ? HashedFile(
            path: r.localPath,
            filename: r.filename,
            totalBytes: r.sizeBytes,
            chunkSizeBytes: r.chunkSizeBytes!,
            chunkHashes: r.chunkHashes!,
            fileHash: r.sha512File,
            lastModifiedMs: r.sourceMtimeMs ?? 0,
            sha1Base64: r.sha1Base64,
          )
        : null;
    if (uploaded != null) {
      log?.call('verify $name: card file not found; saved hashes of the upload used');
      return VerifyHashes(uploaded, VerifyHashSource.saved);
    }
    final cached = await stagedCopyPath(r.localPath);
    final read = await uploader.hashFile(cached ?? r.localPath, onProgress: onProgress);
    log?.call('verify $name: card file not found; checked the phone\'s cached copy');
    return VerifyHashes(read, VerifyHashSource.cachedCopy);
  }
}
