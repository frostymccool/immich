import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/infrastructure/repositories/copyparty_receipt.repository.dart';
import 'package:immich_mobile/services/copyparty/copyparty_saved_hashes.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';

/// Counts reads of the card so the tests can prove when the card is NOT read.
class _CountingUploader extends CopypartyUploaderService {
  int reads = 0;
  _CountingUploader() : super();

  @override
  Future<HashedFile> hashFile(
    String filePath, {
    void Function(int bytesProcessed, int totalBytes)? onProgress,
    Completer<void>? cancelToken,
  }) {
    reads++;
    return super.hashFile(filePath, onProgress: onProgress, cancelToken: cancelToken);
  }
}

void main() {
  late Directory tmp;
  late Drift db;
  late CopypartyReceiptRepository repo;
  late _CountingUploader uploader;
  late SavedHashVerifier verifier;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('cp_saved_hashes_');
    db = Drift(DatabaseConnection(NativeDatabase.memory()));
    await db.customSelect('SELECT 1').get(); // opens the DB: creates the receipts table and its columns
    repo = CopypartyReceiptRepository(db);
    uploader = _CountingUploader();
    verifier = SavedHashVerifier(uploader: uploader, repo: repo, stagedCopyPath: (_) async => null);
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  /// "Uploads" a card file: hashes it once (as the upload does) and writes the receipt with the saved hashes.
  Future<CopypartyReceipt> upload(File card, {bool checked = false}) async {
    final h = await CopypartyUploaderService().hashFile(card.path);
    final id = await repo.insert(
      CopypartyReceipt(
        filename: h.filename,
        localPath: card.path,
        sizeBytes: h.totalBytes,
        sha512File: h.fileHash,
        wark: 'w' * 44,
        uploadTimestamp: DateTime.utc(2026, 5, 2),
        copypartyUrl: 'https://cp.example.test/uploads/${h.filename}',
        uploadConfirmed: true,
        chunkHashes: h.chunkHashes,
        chunkSizeBytes: h.chunkSizeBytes,
        sha1Base64: h.sha1Base64,
        sourceMtimeMs: card.statSync().modified.millisecondsSinceEpoch,
        sourceChecked: checked,
      ),
    );
    return (await repo.getAll()).firstWhere((r) => r.id == id);
  }

  File cardFile(String name, int size) =>
      File('${tmp.path}/$name')..writeAsBytesSync(List.generate(size, (i) => (i * 31 + 7) % 251));

  test('the upload read also gives Immich its SHA-1 (no second read)', () async {
    final f = cardFile('VID_20260502_100000_00_001.mp4', 3 * 1024 * 1024 + 17);
    final h = await CopypartyUploaderService().hashFile(f.path);
    expect(h.sha1Base64, base64.encode(sha1.convert(f.readAsBytesSync()).bytes));
  });

  test('receipts keep the saved hashes (new columns) through the database', () async {
    final f = cardFile('a.mp4', 2 * 1024 * 1024);
    final r = await upload(f);
    expect(r.chunkHashes, isNotEmpty);
    expect(r.sha1Base64, isNotNull);
    expect(r.sourceChecked, isFalse);
  });

  test('saved hashes are not trusted until a second read matched: the first Verify reads the card once', () async {
    final f = cardFile('b.mp4', 2 * 1024 * 1024);
    final r = await upload(f);
    final first = await verifier.hashesFor(r);
    expect(first.source, VerifyHashSource.cardRead);
    expect(first.matchesUpload, isTrue);
    expect(uploader.reads, 1);

    // The match was saved: every later Verify needs no read of the card.
    final again = (await repo.getAll()).single;
    expect(again.sourceChecked, isTrue);
    final second = await verifier.hashesFor(again);
    expect(second.source, VerifyHashSource.saved);
    expect(second.hashed.chunkHashes, first.hashed.chunkHashes);
    expect(second.hashed.sha1Base64, first.hashed.sha1Base64);
    expect(uploader.reads, 1, reason: 'the card was not read again');
  });

  test('a checked receipt verifies without any read', () async {
    final r = await upload(cardFile('c.mp4', 1024 * 1024), checked: true);
    final h = await verifier.hashesFor(r);
    expect(h.source, VerifyHashSource.saved);
    expect(uploader.reads, 0);
  });

  test('a card file changed since the upload is read again and reported as different', () async {
    final f = cardFile('d.mp4', 1024 * 1024);
    final r = await upload(f, checked: true);
    f.writeAsBytesSync(List.filled(1024 * 1024, 1)); // same size, new content and time
    f.setLastModifiedSync(DateTime(2027));
    final h = await verifier.hashesFor(r);
    expect(h.source, VerifyHashSource.cardRead);
    expect(h.matchesUpload, isFalse);
    expect(uploader.reads, 1);
    expect(
      (await repo.getAll()).single.chunkHashes,
      r.chunkHashes,
      reason: 'a mismatch never replaces the saved hashes',
    );
  });

  test('a bad first read (upload hashes differ from the card) is caught by the first Verify', () async {
    final f = cardFile('e.mp4', 1024 * 1024);
    final good = await upload(f);
    // Simulate a bad read at upload: the receipt's whole-file hash does not match the card's real bytes.
    final bad = CopypartyReceipt(
      id: good.id,
      filename: good.filename,
      localPath: good.localPath,
      sizeBytes: good.sizeBytes,
      sha512File: 'not-the-real-hash',
      wark: good.wark,
      uploadTimestamp: good.uploadTimestamp,
      copypartyUrl: good.copypartyUrl,
      chunkHashes: good.chunkHashes,
      chunkSizeBytes: good.chunkSizeBytes,
      sha1Base64: good.sha1Base64,
      sourceMtimeMs: good.sourceMtimeMs,
    );
    final h = await verifier.hashesFor(bad);
    expect(h.matchesUpload, isFalse);
    expect((await repo.getAll()).single.sourceChecked, isFalse, reason: 'never trusted after a mismatch');
  });

  test('a removed card uses the saved hashes of the upload (nothing on the card can be deleted then)', () async {
    final f = cardFile('f.mp4', 1024 * 1024);
    final r = await upload(f);
    f.deleteSync();
    final h = await verifier.hashesFor(r);
    expect(h.source, VerifyHashSource.saved);
    expect(uploader.reads, 0);
  });

  test('older receipts without saved hashes still work (one read)', () async {
    final f = cardFile('g.mp4', 1024 * 1024);
    final h0 = await CopypartyUploaderService().hashFile(f.path);
    final id = await repo.insert(
      CopypartyReceipt(
        filename: 'g.mp4',
        localPath: f.path,
        sizeBytes: h0.totalBytes,
        sha512File: h0.fileHash,
        wark: 'w' * 44,
        uploadTimestamp: DateTime.utc(2026),
        copypartyUrl: 'https://cp.example.test/uploads/g.mp4',
        uploadConfirmed: true,
      ),
    );
    final r = (await repo.getAll()).firstWhere((x) => x.id == id);
    expect(r.chunkHashes, isNull);
    final h = await verifier.hashesFor(r);
    expect(h.source, VerifyHashSource.cardRead);
    expect((await repo.getAll()).single.sourceChecked, isTrue, reason: 'old receipts gain saved hashes too');
  });

  test('an existing receipts table without the new columns gains them', () async {
    final raw = db;
    // Rebuild the table as an older build left it.
    await raw.customStatement('DROP TABLE copyparty_upload_receipts');
    await raw.customStatement('''CREATE TABLE copyparty_upload_receipts (
      id INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT NOT NULL, local_path TEXT NOT NULL,
      size_bytes INTEGER NOT NULL, sha512_file TEXT NOT NULL, wark TEXT NOT NULL, upload_timestamp TEXT NOT NULL,
      copyparty_url TEXT NOT NULL, receipt_file_written INTEGER NOT NULL DEFAULT 0,
      source_deleted INTEGER NOT NULL DEFAULT 0, upload_confirmed INTEGER NOT NULL DEFAULT 0, immich_asset_id TEXT)''');
    await ensureCopypartyReceiptColumns((sql) => raw.customSelect(sql).get(), raw.customStatement);
    await ensureCopypartyReceiptColumns((sql) => raw.customSelect(sql).get(), raw.customStatement); // idempotent
    final cols = (await raw.customSelect("SELECT name FROM pragma_table_info('copyparty_upload_receipts')").get())
        .map((r) => r.data['name'])
        .toSet();
    expect(cols, containsAll(['chunk_hashes', 'chunk_size', 'sha1_b64', 'source_mtime_ms', 'source_checked']));
  });
}
