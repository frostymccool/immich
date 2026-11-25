import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/services/copyparty/copyparty_auto_folder.dart';
import 'package:immich_mobile/services/copyparty/copyparty_camera_info.dart';

// Every value here is synthetic: no real serial numbers, places or paths.

/// An Insta360-style trailer, laid out as exiftool's ProcessInsta360 reads it: records of
/// [data][uint16 id][uint32 len] with the LAST record's footer in the first 6 bytes of the 78-byte tail,
/// the trailer length at tail byte 38 and the magic in the tail's last 32 bytes.
Uint8List insta360Trailer({required String model, required String serial, bool withDirectory = false}) {
  final info = BytesBuilder();
  void entry(int tag, String v) {
    final b = utf8.encode(v);
    info
      ..addByte(tag)
      ..addByte(b.length)
      ..add(b);
  }

  entry(0x0a, serial);
  entry(0x12, model);
  entry(0x1a, 'v0.0.1_build1');
  final infoBytes = info.toBytes();
  final gyro = Uint8List(5000); // stands in for the large gyro record that must never be read

  final out = BytesBuilder();
  void record(int id, Uint8List data, {bool last = false}) {
    out.add(data);
    final f = ByteData(6)
      ..setUint16(0, id, Endian.little)
      ..setUint32(2, data.length, Endian.little);
    if (!last) {
      out.add(f.buffer.asUint8List());
    }
  }

  const infoOffset = 0;
  record(0x101, infoBytes);
  final gyroOffset = out.length;
  final lastId = withDirectory ? 0 : 0x300;
  final Uint8List lastData;
  if (withDirectory) {
    record(0x300, gyro);
    final dir = ByteData(20)
      ..setUint16(0, 0x101, Endian.little)
      ..setUint32(2, infoBytes.length, Endian.little)
      ..setUint32(6, infoOffset, Endian.little)
      ..setUint16(10, 0x300, Endian.little)
      ..setUint32(12, gyro.length, Endian.little)
      ..setUint32(16, gyroOffset, Endian.little);
    lastData = dir.buffer.asUint8List();
  } else {
    lastData = gyro;
  }
  record(lastId, lastData, last: true);
  final tail = ByteData(78)
    ..setUint16(0, lastId, Endian.little)
    ..setUint32(2, lastData.length, Endian.little);
  final trailerLen = out.length + 78;
  tail.setUint32(38, trailerLen, Endian.little);
  final t = tail.buffer.asUint8List();
  t.setRange(46, 78, ascii.encode(CameraInfoReader.insta360Magic));
  out.add(t);
  return out.toBytes();
}

/// A JPEG whose APP1 EXIF has Make, Model, DateTimeOriginal and GPS (little-endian TIFF).
Uint8List jpegWithExif({String make = 'Arashi Vision', String model = 'Insta360 X4', double? lat, double? lon}) {
  final tiff = BytesBuilder();
  final strings = BytesBuilder();
  // Layout: header(8) | IFD0 | ExifIFD | GPS IFD | data area.
  const ifd0Count = 4;
  const exifCount = 1;
  const gpsCount = 4;
  int ifdSize(int n) => 2 + n * 12 + 4;
  const ifd0At = 8;
  final exifAt = ifd0At + ifdSize(ifd0Count);
  final gpsAt = exifAt + ifdSize(exifCount);
  final dataAt = gpsAt + ifdSize(gpsCount);

  int addData(List<int> bytes) {
    final at = dataAt + strings.length;
    strings.add(bytes);
    return at;
  }

  List<int> asciiZ(String s) => [...ascii.encode(s), 0];
  Uint8List entry(int tag, int type, int count, int value) =>
      (ByteData(12)
            ..setUint16(0, tag, Endian.little)
            ..setUint16(2, type, Endian.little)
            ..setUint32(4, count, Endian.little)
            ..setUint32(8, value, Endian.little))
          .buffer
          .asUint8List();
  Uint8List u16(int v) => (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
  Uint8List u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
  List<int> dms(double value) {
    final v = value.abs();
    final d = v.floor();
    final m = ((v - d) * 60).floor();
    final s = ((v - d - m / 60) * 3600 * 1000).round();
    return [...u32(d), ...u32(1), ...u32(m), ...u32(1), ...u32(s), ...u32(1000)];
  }

  final makeB = asciiZ(make);
  final modelB = asciiZ(model);
  final dateB = asciiZ('2026:05:02 14:30:12');
  final makeAt = addData(makeB);
  final modelAt = addData(modelB);
  final dateAt = addData(dateB);
  final latAt = addData(dms(lat ?? 0));
  final lonAt = addData(dms(lon ?? 0));

  tiff
    ..add(ascii.encode('II'))
    ..add(u16(42))
    ..add(u32(ifd0At))
    ..add(u16(ifd0Count))
    ..add(entry(0x010F, 2, makeB.length, makeAt))
    ..add(entry(0x0110, 2, modelB.length, modelAt))
    ..add(entry(0x8769, 4, 1, exifAt))
    ..add(entry(0x8825, 4, 1, gpsAt))
    ..add(u32(0))
    ..add(u16(exifCount))
    ..add(entry(0x9003, 2, dateB.length, dateAt))
    ..add(u32(0))
    ..add(u16(gpsCount));
  // Inline ASCII refs ('N\0', 'W\0' fit in the 4-byte value field).
  Uint8List refEntry(int tag, String r) {
    final e = entry(tag, 2, 2, 0);
    e[8] = ascii.encode(r)[0];
    return e;
  }

  tiff
    ..add(refEntry(1, (lat ?? 0) < 0 ? 'S' : 'N'))
    ..add(entry(2, 5, 3, latAt))
    ..add(refEntry(3, (lon ?? 0) < 0 ? 'W' : 'E'))
    ..add(entry(4, 5, 3, lonAt))
    ..add(u32(0))
    ..add(strings.toBytes());
  final tiffBytes = tiff.toBytes();
  final app1Len = 2 + 6 + tiffBytes.length;
  return Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // a dummy APP0 to skip
    0xFF, 0xE1, app1Len >> 8, app1Len & 0xFF, ...ascii.encode('Exif'), 0, 0, ...tiffBytes,
    0xFF, 0xDA, 0x00, 0x02, // SOS
    1, 2, 3, 0xFF, 0xD9,
  ]);
}

UploadSet setOf(String id, List<String> paths) => UploadSet(
  id: id,
  files: [
    for (final p in paths)
      UploadFile(
        localPath: p,
        filename: p.split('/').last,
        sizeBytes: 1,
        lastModifiedMs: DateTime(2026, 5, 3, 9).millisecondsSinceEpoch,
      ),
  ],
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('cp_autofolder_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String name, List<int> bytes) => File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  group('reading the camera from the files', () {
    test('a video with an Insta360 trailer gives model and serial; the day comes from the name', () async {
      final f = write('VID_20260502_143012_00_057.mp4', [
        ...List.filled(10000, 7),
        ...insta360Trailer(model: 'Insta360 X4', serial: 'TESTSERIAL0001'),
      ]);
      final info = await CameraInfoReader().read(f.path);
      expect(info.model, 'Insta360 X4');
      expect(info.serial, 'TESTSERIAL0001');
      expect(info.day, '2026-05-02');
    });

    test('the info record is found through the directory record too', () async {
      final f = write('VID_20260502_143012_00_058.insv', [
        ...List.filled(100, 1),
        ...insta360Trailer(model: 'GO Ultra', serial: 'TESTSERIAL0002', withDirectory: true),
      ]);
      final info = await CameraInfoReader().read(f.path);
      expect(info.model, 'GO Ultra');
    });

    test('exiftool (the reference parser) reads the same model from these synthetic trailers', () async {
      final exiftool = [
        '/opt/homebrew/bin/exiftool',
        '/usr/bin/exiftool',
        '/usr/local/bin/exiftool',
      ].where((p) => File(p).existsSync()).firstOrNull;
      if (exiftool == null) {
        markTestSkipped('exiftool not installed');
        return;
      }
      for (final dir in [false, true]) {
        // exiftool looks for the trailer only in a file it recognises: a minimal MP4 (ftyp + mdat) first.
        final f = write('VID_20260502_143012_00_09${dir ? 1 : 0}.insv', [
          ...[0, 0, 0, 20],
          ...ascii.encode('ftypisom'),
          ...[0, 0, 2, 0],
          ...ascii.encode('isom'),
          ...[0, 0, 0, 72],
          ...ascii.encode('mdat'),
          ...List.filled(64, 0),
          ...insta360Trailer(model: 'Insta360 X4', serial: 'TESTSERIAL0003', withDirectory: dir),
        ]);
        final r = await Process.run(exiftool, ['-ee', '-s3', '-Model', '-SerialNumber', f.path]);
        expect((r.stdout as String).trim().split('\n'), ['Insta360 X4', 'TESTSERIAL0003'], reason: 'directory=$dir');
        expect((await CameraInfoReader().read(f.path)).model, 'Insta360 X4');
      }
    });

    test('a file without a trailer (cut short) gives no model and does not throw', () async {
      final f = write('VID_20260502_143012_00_001.insv', List.filled(467, 3));
      final info = await CameraInfoReader().read(f.path);
      expect(info.model, isNull);
      expect(info.day, '2026-05-02');
    });

    test('a photo gives model, day and GPS from EXIF', () async {
      final f = write('IMG_0001.jpg', jpegWithExif(lat: -33.5, lon: -70.25));
      final info = await CameraInfoReader().read(f.path);
      expect(info.model, 'Insta360 X4');
      expect(info.day, '2026-05-02');
      expect(info.lat, closeTo(-33.5, 1e-4));
      expect(info.lon, closeTo(-70.25, 1e-4));
    });

    test('a photo with GPS 0,0 counts as no GPS', () {
      final info = CameraInfoReader.parseExif(jpegWithExif(lat: 0, lon: 0));
      expect(info.hasGps, isFalse);
    });

    test('garbage never throws', () {
      expect(CameraInfoReader.parseExif(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF])).model, isNull);
      expect(CameraInfoReader.parseExif(Uint8List(0)).model, isNull);
    });
  });

  group('folder names', () {
    test('camera names are shortened', () {
      expect(shortCameraName('Insta360 X4'), 'X4');
      expect(shortCameraName('Insta360 GO Ultra'), 'GO Ultra');
      expect(shortCameraName('HERO9 Black'), 'HERO9 Black');
      expect(shortCameraName('GoPro HERO12 Black'), 'HERO12 Black');
      expect(shortCameraName(null), isNull);
    });

    test('place names lose Latin accents and unsafe characters', () {
      expect(placeForFolder('Málaga'), 'Malaga');
      expect(placeForFolder('São Paulo'), 'Sao Paulo');
      expect(placeForFolder('A/B: C'), 'A B C');
      expect(sanitizeFolderName('..hidden'), 'hidden');
    });

    test('Place date camera, one folder per day and camera', () {
      final facts = [
        const SetFacts(
          setId: 'a',
          day: '2026-05-02',
          info: CameraFileInfo(model: 'Insta360 X4'),
        ),
        const SetFacts(
          setId: 'b',
          day: '2026-05-02',
          info: CameraFileInfo(model: 'Insta360 GO Ultra'),
        ),
        const SetFacts(
          setId: 'c',
          day: '2026-05-03',
          info: CameraFileInfo(model: 'Insta360 X4'),
        ),
      ];
      final plan = planFolders(facts, {'2026-05-02': 'Lisbon', '2026-05-03': null});
      expect(plan.folderBySet, {'a': 'Lisbon 2026-05-02 X4', 'b': 'Lisbon 2026-05-02 GO Ultra', 'c': '2026-05-03 X4'});
    });

    test('a set with no readable model takes the most common camera, else "Camera"', () {
      final plan = planFolders([
        const SetFacts(
          setId: 'a',
          day: '2026-05-02',
          info: CameraFileInfo(model: 'Insta360 X4'),
        ),
        const SetFacts(setId: 'b', day: '2026-05-02', info: CameraFileInfo.empty),
      ], {});
      expect(plan.folderBySet['b'], '2026-05-02 X4');
      expect(
        planFolders([const SetFacts(setId: 'x', day: '2026-05-02', info: CameraFileInfo.empty)], {}).folderBySet['x'],
        '2026-05-02 Camera',
      );
    });

    test('two cameras of the same model get the last 4 serial characters', () {
      final plan = planFolders([
        const SetFacts(
          setId: 'a',
          day: '2026-05-02',
          info: CameraFileInfo(model: 'Insta360 X4', serial: 'TESTAAAA1111'),
        ),
        const SetFacts(
          setId: 'b',
          day: '2026-05-02',
          info: CameraFileInfo(model: 'Insta360 X4', serial: 'TESTBBBB2222'),
        ),
      ], {});
      expect(plan.folderBySet.values.toSet(), {'2026-05-02 X4 1111', '2026-05-02 X4 2222'});
    });

    test('renames apply to every set in that folder', () {
      const plan = AutoFolderPlan({'a': '2026-05-02 X4', 'b': '2026-05-02 X4'});
      expect(plan.renamed({'2026-05-02 X4': 'Reef dive/2'}).folderBySet.values.toSet(), {'Reef dive 2'});
      expect(autoFolderUploadPath('/uploads/', 'Lisbon 2026-05-02 X4'), '/uploads/Lisbon 2026-05-02 X4');
    });
  });

  group('planning an import', () {
    test('GPS in a photo wins over the phone; the phone is used only for recent days; never blocks', () async {
      final lookups = <String>[];
      var phoneAsked = 0;
      final svc = AutoFolderService(
        readInfo: (path) async => switch (path) {
          '/card/IMG_20260502_100000_00_001.insp' => const CameraFileInfo(
            model: 'Insta360 X4',
            day: '2026-05-02',
            lat: 10,
            lon: 20,
          ),
          '/card/VID_20260503_100000_00_002.insv' => const CameraFileInfo(model: 'Insta360 X4', day: '2026-05-03'),
          '/card/VID_20260410_100000_00_003.insv' => const CameraFileInfo(model: 'Insta360 X4', day: '2026-04-10'),
          _ => CameraFileInfo.empty,
        },
        reverseGeocode: (lat, lon) async {
          lookups.add('$lat,$lon');
          return lat == 10 ? 'Málaga' : 'Testville';
        },
        phoneLocation: () async {
          phoneAsked++;
          return (1.0, 2.0);
        },
        now: () => DateTime(2026, 5, 3, 18),
      );
      final plan = await svc.plan([
        setOf('s1', ['/card/IMG_20260502_100000_00_001.insp']),
        setOf('s2', ['/card/VID_20260503_100000_00_002.insv', '/card/LRV_20260503_100000_01_002.lrv']),
        setOf('s3', ['/card/VID_20260410_100000_00_003.insv']),
      ]);
      expect(plan.folderBySet, {'s1': 'Malaga 2026-05-02 X4', 's2': 'Testville 2026-05-03 X4', 's3': '2026-04-10 X4'});
      expect(phoneAsked, 1);
      expect(lookups, ['10.0,20.0', '1.0,2.0']);
    });

    test('a failing place lookup leaves the place out', () async {
      final svc = AutoFolderService(
        readInfo: (_) async => const CameraFileInfo(model: 'Insta360 X4', day: '2026-05-03'),
        reverseGeocode: (_, _) async => throw const SocketException('offline'),
        phoneLocation: () async => (1.0, 2.0),
        now: () => DateTime(2026, 5, 3),
      );
      final plan = await svc.plan([
        setOf('s', ['/card/VID_20260503_100000_00_002.insv']),
      ]);
      expect(plan.folderBySet['s'], '2026-05-03 X4');
    });

    test('without a date in the files or names, the modification day is used', () async {
      final svc = AutoFolderService(
        readInfo: (_) async => CameraFileInfo.empty,
        reverseGeocode: (_, _) async => null,
        phoneLocation: () async => null,
        now: () => DateTime(2026, 6, 1),
      );
      final plan = await svc.plan([
        setOf('s', ['/card/GX010123.MP4']),
      ]);
      expect(plan.folderBySet['s'], '2026-05-03 Camera');
    });
  });
}
