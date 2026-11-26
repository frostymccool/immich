import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/services/copyparty/copyparty_auto_folder.dart';
import 'package:immich_mobile/services/copyparty/copyparty_camera_info.dart';
import 'package:immich_mobile/services/copyparty/copyparty_run_rules.dart';
import 'package:immich_mobile/services/copyparty/copyparty_staging.service.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';

/// Regression tests for bugs found on the phone with builds 302–304.
void main() {
  group('check of an original before deleting it', () {
    test('hashes the whole file', () async {
      final bytes = List<int>.generate(300000, (i) => i % 251);
      final hex = await sha512OfStream(Stream.fromIterable([bytes.sublist(0, 1000), bytes.sublist(1000)]));
      expect(hex, sha512.convert(bytes).toString());
    });

    test('a card read that stops answering gives up instead of holding every later check', () async {
      // Bug: every finished file showed "Waiting to check the original before deleting it" and nothing moved.
      final stalled = StreamController<List<int>>();
      stalled.add([1, 2, 3]); // some data, then nothing
      await expectLater(
        sha512OfStream(stalled.stream, stallTimeout: const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
      await stalled.close();
    });

    test('Stop or Keep original stops the read', () async {
      await expectLater(
        sha512OfStream(
          Stream.fromIterable([
            [1],
            [2],
          ]),
          stopped: () => true,
        ),
        throwsA(isA<CopypartyCancelledException>()),
      );
    });
  });

  group('Stop', () {
    test('Stop on a paused run finishes it (it used to do nothing and stay on the paused screen)', () {
      expect(stopActionFor(running: false, onProgressPage: true), StopAction.finishPaused);
    });

    test('Stop on a running upload cancels it', () {
      expect(stopActionFor(running: true, onProgressPage: true), StopAction.cancelRun);
    });

    test('Stop with nothing on the progress page does nothing', () {
      expect(stopActionFor(running: false, onProgressPage: false), StopAction.nothing);
    });
  });

  group('pause card copy', () {
    final files = [(name: 'a', cached: true), (name: 'b', cached: false), (name: 'c', cached: true)];

    test('only files already in the phone cache may upload', () {
      final now = uploadableNow(files, cardPaused: true, useCache: true, isCached: (f) => f.cached);
      expect(now.map((f) => f.name), ['a', 'c']);
    });

    test('nothing cached: nothing may upload, the run waits instead of reading the card', () {
      final now = uploadableNow(
        files.where((f) => !f.cached).toList(),
        cardPaused: true,
        useCache: true,
        isCached: (f) => f.cached,
      );
      expect(now, isEmpty);
    });

    test('not paused, or no phone cache: every pending file may go', () {
      expect(uploadableNow(files, cardPaused: false, useCache: true, isCached: (f) => f.cached), hasLength(3));
      expect(uploadableNow(files, cardPaused: true, useCache: false, isCached: (f) => f.cached), hasLength(3));
    });
  });

  group('upload from the phone cache keeps the destination folder', () {
    // Bug: files queued from the cache showed no destination and went to the plain upload folder, so a
    // partial in the automatic folder then made the upload fail as "stale/incomplete upload".
    test('the folder it was already uploaded to wins', () {
      expect(
        cachedFileFolder(
          receiptUrl: 'https://cp.example.test/up/Seaside%202026-07-01%20X4/VID_1.insv',
          cachedUploadPath: '/up/Other',
        ),
        '/up/Seaside 2026-07-01 X4',
      );
    });

    test('else the folder chosen when it was cached', () {
      expect(cachedFileFolder(cachedUploadPath: '/up/Seaside 2026-07-01 X4'), '/up/Seaside 2026-07-01 X4');
    });

    test('else nothing: it is planned like a new import', () {
      expect(cachedFileFolder(), isNull);
      expect(cachedFileFolder(cachedUploadPath: '  '), isNull);
      expect(folderOfCopypartyUrl('https://cp.example.test/a.jpg'), isNull);
    });

    test('the cache records the folder with the copy', () async {
      final tmp = Directory.systemTemp.createTempSync('cp_stage_folder_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final card = File('${tmp.path}/IMG_20260701_101010_00_001.jpg')..writeAsBytesSync(List.filled(4096, 7));
      final staging = CopypartyStagingService(
        CopypartyUploaderService(),
        stagingDirProvider: () async => Directory('${tmp.path}/cache'),
      );
      await staging.stage(card.path, uploadPath: '/up/Seaside 2026-07-01 X4');
      final other = File('${tmp.path}/IMG_20260701_101011_00_002.jpg')..writeAsBytesSync(List.filled(10, 1));
      await staging.stage(other.path); // older builds: no folder
      final entries = await staging.listEntries();
      expect(entries.firstWhere((e) => e.sourcePath == card.path).uploadPath, '/up/Seaside 2026-07-01 X4');
      expect(entries.firstWhere((e) => e.sourcePath == other.path).uploadPath, isNull);
    });

    test('planning a cached file reads the cached copy when the card is gone', () async {
      final read = <String>[];
      final service = AutoFolderService(
        readInfo: (p) async {
          read.add(p);
          return CameraFileInfo.empty;
        },
        placeNames: (_, _) async => const [],
        phoneLocation: () async => null,
      );
      await service.readingFrom((p) => p == '/card/a.jpg' ? '/cache/a.jpg' : p).readInfo('/card/a.jpg');
      expect(read, ['/cache/a.jpg']);
    });
  });
}
