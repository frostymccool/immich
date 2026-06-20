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
         upload_timestamp, copyparty_url, receipt_file_written, source_deleted)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
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
      ],
    );
  }

  Future<void> markReceiptWritten(int id) async {
    await _db.customStatement(
      'UPDATE copyparty_upload_receipts SET receipt_file_written = 1 WHERE id = ?',
      [id],
    );
  }

  Future<void> markSourceDeleted(int id) async {
    await _db.customStatement(
      'UPDATE copyparty_upload_receipts SET source_deleted = 1 WHERE id = ?',
      [id],
    );
  }

  Future<List<CopypartyReceipt>> getAll() async {
    final rows = await _db.customSelect(
      'SELECT * FROM copyparty_upload_receipts ORDER BY upload_timestamp DESC',
    ).get();
    return rows.map(_rowToReceipt).toList();
  }

  Future<CopypartyReceipt?> getByWark(String wark) async {
    final rows = await _db.customSelect(
      'SELECT * FROM copyparty_upload_receipts WHERE wark = ? LIMIT 1',
      variables: [Variable.withString(wark)],
    ).get();
    if (rows.isEmpty) return null;
    return _rowToReceipt(rows.first);
  }

  Future<List<CopypartyReceipt>> getPendingDeletion() async {
    final rows = await _db.customSelect(
      '''SELECT * FROM copyparty_upload_receipts
         WHERE receipt_file_written = 1 AND source_deleted = 0
         ORDER BY upload_timestamp DESC''',
    ).get();
    return rows.map(_rowToReceipt).toList();
  }

  Future<void> delete(int id) async {
    await _db.customStatement(
      'DELETE FROM copyparty_upload_receipts WHERE id = ?',
      [id],
    );
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
    );
  }
}
