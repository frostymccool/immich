import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
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

  group('resume choices after Pause', () {
    test('Resume all turns everything back on', () {
      expect(pausesForResume(ResumeMode.all, useCache: true), (cardPaused: false, uploadsPaused: false));
    });

    test('Cache only copies the card into the phone cache and sends nothing', () {
      expect(pausesForResume(ResumeMode.cacheOnly, useCache: true), (cardPaused: false, uploadsPaused: true));
    });

    test('Upload only sends cached files and leaves the card alone', () {
      expect(pausesForResume(ResumeMode.uploadOnly, useCache: true), (cardPaused: true, uploadsPaused: false));
    });

    test('without the phone cache every choice resumes everything', () {
      for (final mode in ResumeMode.values) {
        expect(pausesForResume(mode, useCache: false), (cardPaused: false, uploadsPaused: false));
      }
    });
  });

  group('stack RAW with its JPG', () {
    test('a NEF and its JPG stack with the JPG as the cover', () {
      expect(rawJpgStack([(filename: 'DSC_0042.NEF', assetId: 'raw'), (filename: 'DSC_0042.JPG', assetId: 'jpg')]), [
        'jpg',
        'raw',
      ]);
    });

    test('not until both are in Immich', () {
      expect(
        rawJpgStack([(filename: 'P1010001.ORF', assetId: 'raw'), (filename: 'P1010001.JPG', assetId: null)]),
        isNull,
      );
    });

    test('nothing to stack without a RAW, or without a JPG', () {
      expect(rawJpgStack([(filename: 'IMG_0001.JPG', assetId: 'a')]), isNull);
      expect(rawJpgStack([(filename: 'DSC_0001.ARW', assetId: 'a')]), isNull);
      expect(
        rawJpgStack([(filename: 'VID_0001.MP4', assetId: 'v'), (filename: 'VID_0001.LRF', assetId: null)]),
        isNull,
      );
    });

    test('side files do not hold the stack back', () {
      expect(
        rawJpgStack([
          (filename: 'DSC_0042.NEF', assetId: 'raw'),
          (filename: 'DSC_0042.JPG', assetId: 'jpg'),
          (filename: 'DSC_0042.NEF.xmp', assetId: null),
        ]),
        ['jpg', 'raw'],
      );
    });

    test('the same asset twice (Immich already had it) is listed once', () {
      expect(rawJpgStack([(filename: 'A.DNG', assetId: 'same'), (filename: 'A.JPG', assetId: 'same')]), isNull);
    });
  });

  group('delete originals: one-time choice per import', () {
    test('no choice made: the setting decides', () {
      expect(shouldAutoDelete(setting: true), isTrue);
      expect(shouldAutoDelete(setting: false), isFalse);
    });

    test('turned off for this import (testing): originals are kept even with the setting on', () {
      expect(shouldAutoDelete(setting: true, override: false), isFalse);
    });

    test('turned on for this import: originals are deleted even with the setting off', () {
      expect(shouldAutoDelete(setting: false, override: true), isTrue);
    });
  });

  group('deleting originals with two cards', () {
    // Bug: with two card readers, a delete check that failed on one card ("No such file or directory") kept the
    // originals of EVERY card for the rest of the run, with an unclear message.
    test('each card is its own volume', () {
      expect(cardVolumeOf('/storage/EB55-F36E/DCIM/CAM_001/CAM_1.LRF'), '/storage/EB55-F36E');
      expect(cardVolumeOf('/storage/FBFD-F67D/DCIM/Camera01/VID_1.insv'), '/storage/FBFD-F67D');
      expect(cardVolumeOf('/storage/emulated/0/DCIM/a.jpg'), '/storage/emulated/0');
      expect(cardVolumeOf('/mnt/media_rw/EB55-F36E/DCIM/a.jpg'), '/mnt/media_rw/EB55-F36E');
      expect(cardNameOf('/storage/EB55-F36E'), 'EB55-F36E');
    });

    test('a missing file never stops deletes on the card', () {
      expect(blocksWholeCard('No such file or directory'), isFalse);
      expect(blocksWholeCard('Cannot delete file, path = x (OS Error: No such file or directory, errno = 2)'), isFalse);
    });

    test('a read-only card or a refused permission stops deletes on that card', () {
      expect(blocksWholeCard('Read-only file system'), isTrue);
      expect(blocksWholeCard('Permission denied'), isTrue);
      expect(blocksWholeCard('no folder permission covers this path'), isTrue);
    });
  });

  group('cache warning says the real cause', () {
    // Bug: "N files could not be cached (phone storage full)" was shown for every copy failure, while the
    // cache was working and had plenty of room.
    test('causes are told apart', () {
      expect(cacheFailureOf('FileSystemException: No space left on device, errno = 28'), CacheFailure.phoneFull);
      expect(
        cacheFailureOf('PathNotFoundException: No such file or directory, errno = 2, path'),
        CacheFailure.cardUnreadable,
      );
      expect(cacheFailureOf('Exception: something else'), CacheFailure.other);
    });

    test('"phone storage full" only when it is', () {
      final w = cacheFailureWarnings({CacheFailure.cardUnreadable: 22});
      expect(w.single, contains('could not be read from the card'));
      expect(w.single, isNot(contains('storage full')));
      expect(cacheFailureWarnings({CacheFailure.phoneFull: 1}).single, contains('phone storage full'));
      expect(cacheFailureWarnings({}), isEmpty);
    });
  });

  group('Resume finishes deletes that Pause cut short', () {
    // Bug: with auto-delete on, files that finished uploading before a Pause kept their originals after Resume.
    UploadFile file(String name, {int? interrupted, bool? deleteChoice}) =>
        UploadFile(localPath: '/storage/EB55-F36E/DCIM/$name', filename: name, sizeBytes: 10, lastModifiedMs: 0)
          ..deleteInterruptedReceiptId = interrupted
          ..deleteOriginalOverride = deleteChoice;

    test('an interrupted delete is finished on Resume', () {
      final files = [file('a.jpg', interrupted: 7), file('b.jpg')];
      expect(deletesToFinish(files, setting: true).map((f) => f.filename), ['a.jpg']);
    });

    test('not when deleting was turned off for those files, or by the setting', () {
      expect(deletesToFinish([file('a.jpg', interrupted: 7, deleteChoice: false)], setting: true), isEmpty);
      expect(deletesToFinish([file('a.jpg', interrupted: 7)], setting: false), isEmpty);
    });

    test('only files of the resumed selection', () {
      final files = [file('a.jpg', interrupted: 7), file('b.jpg', interrupted: 8)];
      expect(
        deletesToFinish(files, selected: {'/storage/EB55-F36E/DCIM/b.jpg'}, setting: true).map((f) => f.filename),
        ['b.jpg'],
      );
    });
  });
}
