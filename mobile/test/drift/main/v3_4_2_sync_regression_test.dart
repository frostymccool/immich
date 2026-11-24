// dart format width=80
// Regression test for the v3.4.2 sync (third renumbering of the fork's raw-SQL
// copyparty schema versions). Installed custom builds up to 3.3.5-custom.271
// store user_version 37 (older ones 35 or 36), but their real drift content is
// upstream v34 plus the copyparty receipts table. Upstream's real v35 adds
// group_date to the asset tables, so trusting the stored version would skip
// that step. This builds such a device and checks onUpgrade repairs it
// without losing copyparty receipts.
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';

import 'generated/schema_v34.dart' as v34;

const _copypartyTableSql = '''
  CREATE TABLE IF NOT EXISTS copyparty_upload_receipts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filename TEXT NOT NULL,
    local_path TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    sha512_file TEXT NOT NULL,
    wark TEXT NOT NULL,
    upload_timestamp TEXT NOT NULL,
    copyparty_url TEXT NOT NULL,
    receipt_file_written INTEGER NOT NULL DEFAULT 0,
    source_deleted INTEGER NOT NULL DEFAULT 0,
    upload_confirmed INTEGER NOT NULL DEFAULT 0,
    immich_asset_id TEXT
  )
''';

/// Real content: upstream v34 + the full copyparty table with one receipt,
/// stamped with [storedUserVersion] from the old fork numbering.
Future<void> _buildDevice(String path, {required int storedUserVersion}) async {
  final v34Db = v34.DatabaseAtV34(NativeDatabase(File(path)));
  await v34Db.customSelect('SELECT 1').getSingle();
  await v34Db.close();

  final raw = NativeDatabase(File(path));
  await raw.ensureOpen(_NoopExecutorUser());
  await raw.runCustom(_copypartyTableSql, const []);
  await raw.runCustom(
    'CREATE INDEX IF NOT EXISTS idx_copyparty_receipts_wark ON copyparty_upload_receipts(wark)',
    const [],
  );
  await raw.runCustom(
    "INSERT INTO copyparty_upload_receipts (filename, local_path, size_bytes, sha512_file, wark, upload_timestamp, copyparty_url, upload_confirmed) VALUES ('a.jpg', '/x/a.jpg', 3, 'h', 'w1', '2026-11-20T00:00:00Z', 'https://copyparty.example/ian/a.jpg', 1)",
    const [],
  );
  await raw.runCustom('PRAGMA user_version = $storedUserVersion', const []);
  await raw.close();
}

class _NoopExecutorUser extends QueryExecutorUser {
  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<String> tempDbPath(String name) async {
    final path =
        '${Directory.systemTemp.path}/v3_4_2_regression_${name}_${DateTime.now().microsecondsSinceEpoch}.sqlite';
    for (final p in [path, '$path-wal', '$path-shm']) {
      final f = File(p);
      if (f.existsSync()) {
        f.deleteSync();
      }
    }
    return path;
  }

  Future<void> expectRepaired(String path) async {
    final db = Drift(DatabaseConnection(NativeDatabase(File(path))));
    await db.customSelect('SELECT 1').getSingle();

    final userVersion = (await db
            .customSelect('PRAGMA user_version')
            .getSingle())
        .read<int>('user_version');
    expect(userVersion, db.schemaVersion);

    for (final table in ['local_asset_entity', 'remote_asset_entity']) {
      final cols = await db
          .customSelect("SELECT name FROM pragma_table_info('$table')")
          .get();
      expect(
        cols.any((r) => r.data['name'] == 'group_date'),
        isTrue,
        reason: '$table.group_date (real upstream v35) must be added',
      );
    }

    final indexes = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
        .get();
    expect(
      indexes.map((r) => r.data['name']),
      containsAll([
        'idx_local_asset_group',
        'idx_remote_asset_group',
        'idx_copyparty_receipts_wark',
      ]),
    );

    final receipts = await db
        .customSelect(
          'SELECT wark, upload_confirmed FROM copyparty_upload_receipts',
        )
        .get();
    expect(receipts, hasLength(1), reason: 'existing receipts must survive');
    expect(receipts.single.data['wark'], 'w1');
    expect(receipts.single.data['upload_confirmed'], 1);

    await db.close();
  }

  for (final stored in [35, 36, 37]) {
    test(
      'device stored at v$stored (real content v34 + copyparty) gains group_date and keeps receipts',
      () async {
        final path = await tempDbPath('stored_$stored');
        await _buildDevice(path, storedUserVersion: stored);
        await expectRepaired(path);
      },
    );
  }

  test('a second open after the upgrade is a no-op', () async {
    final path = await tempDbPath('reopen');
    await _buildDevice(path, storedUserVersion: 37);
    await expectRepaired(path);
    await expectRepaired(path);
  });
}
