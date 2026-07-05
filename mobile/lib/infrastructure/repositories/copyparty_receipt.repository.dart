import 'package:drift/drift.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

class CopypartyReceiptRepository {
  final Drift _db;

  const CopypartyReceiptRepository(this._db);

  Future<int> insert(CopypartyReceipt receipt) async {
    return _db.customInsert(
      '''
      INSERT INTO copyparty_upload_receipts
        (filename, local_path, size_bytes, sha512_file, wark,
         upload_timestamp, copyparty_url, receipt_file_written, source_deleted,
         upload_confirmed, immich_asset_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      variables: [
        Variable.withString(receipt.filename),
        Variable.withString(receipt.localPath),
        Variable.withInt(receipt.sizeBytes),
        Variable.withString(receipt.sha512File),
        Variable.withString(receipt.wark),
        Variable.withString(receipt.uploadTimestamp.toIso8601String()),
        Variable.withString(receipt.copypartyUrl),
        Variable.withInt(receipt.receiptFileWritten ? 1 : 0),
        Variable.withInt(receipt.sourceDeleted ? 1 : 0),
        Variable.withInt(receipt.uploadConfirmed ? 1 : 0),
        receipt.immichAssetId != null ? Variable.withString(receipt.immichAssetId!) : const Variable(null),
      ],
    );
  }

  Future<void> markReceiptWritten(int id) async {
    await _db.customStatement('UPDATE copyparty_upload_receipts SET receipt_file_written = 1 WHERE id = ?', [id]);
  }

  Future<void> markSourceDeleted(int id) async {
    await _db.customStatement('UPDATE copyparty_upload_receipts SET source_deleted = 1 WHERE id = ?', [id]);
  }

  Future<void> markImmichUploaded(int id, String assetId) async {
    await _db.customStatement('UPDATE copyparty_upload_receipts SET immich_asset_id = ? WHERE id = ?', [assetId, id]);
  }

  Future<List<CopypartyReceipt>> getAll() async {
    final rows = await _db.customSelect('SELECT * FROM copyparty_upload_receipts ORDER BY upload_timestamp DESC').get();
    return rows.map(_rowToReceipt).toList();
  }

  Future<CopypartyReceipt?> getByWark(String wark) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM copyparty_upload_receipts WHERE wark = ? LIMIT 1',
          variables: [Variable.withString(wark)],
        )
        .get();
    if (rows.isEmpty) {
      return null;
    }
    return _rowToReceipt(rows.first);
  }

  /// Returns the most recent confirmed upload receipt for the given local path,
  /// or null if no confirmed upload exists.
  Future<CopypartyReceipt?> findByLocalPath(String localPath) async {
    final rows = await _db
        .customSelect(
          '''SELECT * FROM copyparty_upload_receipts
         WHERE local_path = ? AND upload_confirmed = 1 AND source_deleted = 0
         ORDER BY upload_timestamp DESC LIMIT 1''',
          variables: [Variable.withString(localPath)],
        )
        .get();
    if (rows.isEmpty) {
      return null;
    }
    return _rowToReceipt(rows.first);
  }

  Future<List<CopypartyReceipt>> getPendingDeletion() async {
    final rows = await _db.customSelect('''SELECT * FROM copyparty_upload_receipts
         WHERE receipt_file_written = 1 AND source_deleted = 0
         ORDER BY upload_timestamp DESC''').get();
    return rows.map(_rowToReceipt).toList();
  }

  /// Returns one receipt per local_path (most recent confirmed upload),
  /// for files not yet deleted from device.
  Future<List<CopypartyReceipt>> getUndeleted() async {
    final rows = await _db.customSelect('''SELECT * FROM copyparty_upload_receipts
         WHERE upload_confirmed = 1 AND source_deleted = 0
         ORDER BY upload_timestamp DESC''').get();
    // Deduplicate by local_path — first occurrence is most recent (DESC order).
    final seen = <String>{};
    final result = <CopypartyReceipt>[];
    for (final row in rows.map(_rowToReceipt)) {
      if (seen.add(row.localPath)) {
        result.add(row);
      }
    }
    return result;
  }

  Future<void> delete(int id) async {
    await _db.customStatement('DELETE FROM copyparty_upload_receipts WHERE id = ?', [id]);
  }

  static CopypartyReceipt _rowToReceipt(QueryRow row) {
    final data = row.data;
    return CopypartyReceipt(
      id: data['id'] as int?,
      filename: data['filename'] as String,
      localPath: data['local_path'] as String,
      sizeBytes: data['size_bytes'] as int,
      sha512File: data['sha512_file'] as String,
      wark: data['wark'] as String,
      uploadTimestamp: DateTime.parse(data['upload_timestamp'] as String),
      copypartyUrl: data['copyparty_url'] as String,
      receiptFileWritten: (data['receipt_file_written'] as int) == 1,
      sourceDeleted: (data['source_deleted'] as int) == 1,
      uploadConfirmed: (data['upload_confirmed'] as int? ?? 0) == 1,
      immichAssetId: data['immich_asset_id'] as String?,
    );
  }
}
