// dart format width=80
// Regression test for the v3.3.3-sync DB migration bug: devices on this
// fork's OLD copyparty raw-SQL numbering (user_version 32/33, meaning real
// upstream v31 content + copyparty table/columns) collided with upstream's
// own schema growing into that same numeric range in the v3.3.3 release.
// This simulates the two real device states and verifies onUpgrade repairs
// both of them.
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';

import 'generated/schema_v31.dart' as v31;

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
    source_deleted INTEGER NOT NULL DEFAULT 0
  )
''';

/// Builds a file-backed DB whose real schema content is genuine upstream v31
/// plus the fork's copyparty raw-SQL table/columns layered on top (exactly
/// what the pre-v3.3.3-sync onUpgrade produced for real devices), then
/// stamps it with [storedUserVersion] to simulate either the old pre-sync
/// numbering (33) or the already-broken post-build-129 state (36).
Future<void> _buildOldSchemeDevice(
  String path, {
  required int storedUserVersion,
}) async {
  final v31Db = v31.DatabaseAtV31(NativeDatabase(File(path)));
  await v31Db.customSelect('SELECT 1').getSingle();
  await v31Db.close();

  final raw = NativeDatabase(File(path));
  await raw.ensureOpen(_NoopExecutorUser());
  await raw.runCustom(_copypartyTableSql, const []);
  await raw.runCustom(
    'CREATE INDEX IF NOT EXISTS idx_copyparty_receipts_wark ON copyparty_upload_receipts(wark)',
    const [],
  );
  await raw.runCustom(
    'ALTER TABLE copyparty_upload_receipts ADD COLUMN upload_confirmed INTEGER NOT NULL DEFAULT 0',
    const [],
  );
  await raw.runCustom(
    'ALTER TABLE copyparty_upload_receipts ADD COLUMN immich_asset_id TEXT',
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

  Future<void> expectRepaired(String path) async {
    final db = Drift(DatabaseConnection(NativeDatabase(File(path))));
    // Force the migration to run.
    await db.customSelect('SELECT 1').getSingle();

    final userVersion =
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        );
    expect(
      userVersion,
      37,
      reason: 'user_version should land on the new schemaVersion',
    );

    final localAssetCols = await db
        .customSelect(
          "SELECT name FROM pragma_table_info('local_asset_entity')",
        )
        .get();
    expect(
      localAssetCols.any((r) => r.data['name'] == 'previous_checksum'),
      isTrue,
      reason:
          'previous_checksum must exist after migration (this is what crashed hashing/sync)',
    );

    final assetFaceFks = await db
        .customSelect(
          "SELECT * FROM pragma_foreign_key_list('asset_face_entity')",
        )
        .get();
    expect(
      assetFaceFks,
      isEmpty,
      reason: 'asset_face FK constraints must be removed',
    );

    final receiptCols = await db
        .customSelect(
          "SELECT name FROM pragma_table_info('copyparty_upload_receipts')",
        )
        .get();
    final receiptColNames = receiptCols
        .map((r) => r.data['name'] as String)
        .toSet();
    expect(
      receiptColNames,
      containsAll(['upload_confirmed', 'immich_asset_id']),
    );

    await db.close();
  }

  Future<String> tempDbPath(String name) async {
    final path =
        '${Directory.systemTemp.path}/v3_3_3_regression_${name}_${DateTime.now().microsecondsSinceEpoch}.sqlite';
    for (final p in [path, '$path-wal', '$path-shm']) {
      final f = File(p);
      if (f.existsSync()) {
        f.deleteSync();
      }
    }
    return path;
  }

  test(
    'device on the OLD fork numbering (stored v33, real content v31) migrates correctly on first upgrade',
    () async {
      final path = await tempDbPath('scenario_a');
      await _buildOldSchemeDevice(path, storedUserVersion: 33);
      await expectRepaired(path);
    },
  );

  test(
    'device already stuck on the broken build (stored v36, real content still v31) self-heals',
    () async {
      final path = await tempDbPath('scenario_b');
      await _buildOldSchemeDevice(path, storedUserVersion: 36);
      await expectRepaired(path);
    },
  );
}
