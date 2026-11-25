import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';

void main() {
  test('the streamed chunk id equals the whole-chunk id however the bytes are sliced', () {
    final rnd = Random(7);
    final chunk = Uint8List.fromList(List<int>.generate(3 * 1024 * 1024 + 17, (_) => rnd.nextInt(256)));
    final expected = CopypartyUploaderService.chunkIdOf(chunk);
    for (final slice in [1, 4096, 65536, 1024 * 1024, chunk.length]) {
      final h = ChunkIdHasher();
      for (var i = 0; i < chunk.length; i += slice) {
        h.add(chunk.sublist(i, min(i + slice, chunk.length)));
      }
      expect(h.close(), expected, reason: 'slice $slice');
    }
  });

  test('hashFile gives the same chunk ids as hashing each whole chunk', () async {
    final dir = Directory.systemTemp.createTempSync('cp_chunks_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final rnd = Random(11);
    final bytes = Uint8List.fromList(List<int>.generate(5 * 1024 * 1024 + 123, (_) => rnd.nextInt(256)));
    final f = File('${dir.path}/a.bin')..writeAsBytesSync(bytes);
    final hashed = await CopypartyUploaderService().hashFile(f.path);
    final size = hashed.chunkSizeBytes;
    final expected = [
      for (var i = 0; i < bytes.length; i += size)
        CopypartyUploaderService.chunkIdOf(bytes.sublist(i, min(i + size, bytes.length))),
    ];
    expect(hashed.chunkHashes, expected);
  });

  group('staging copy (card → phone cache)', () {
    late Directory dir;
    late Uint8List bytes;
    late File source;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('cp_stage_');
      final rnd = Random(3);
      bytes = Uint8List.fromList(List<int>.generate(5 * 1024 * 1024 + 321, (_) => rnd.nextInt(256)));
      source = File('${dir.path}/src.bin')..writeAsBytesSync(bytes);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    List<String> expectedIds(int size) => [
      for (var i = 0; i < bytes.length; i += size)
        CopypartyUploaderService.chunkIdOf(bytes.sublist(i, min(i + size, bytes.length))),
    ];

    test('a fresh copy is byte-identical with the same chunk ids as hashFile', () async {
      final svc = CopypartyUploaderService();
      final staged = '${dir.path}/staged.bin';
      final h = await svc.stageAndHash(source.path, staged);
      expect(File(staged).readAsBytesSync(), bytes);
      expect(h.chunkHashes, expectedIds(h.chunkSizeBytes));
      expect(h.fileHash, (await svc.hashFile(source.path)).fileHash);
    });

    test('resuming over a half-written chunk trims it and still ends byte-identical', () async {
      final svc = CopypartyUploaderService();
      final size = svc.computeChunkSizeBytes(bytes.length);
      final staged = '${dir.path}/staged.bin';
      // One complete chunk plus part of the next, as a cancel mid-chunk now leaves it.
      File(staged).writeAsBytesSync(bytes.sublist(0, size + size ~/ 3));
      final h = await svc.stageAndHash(source.path, staged);
      expect(File(staged).lengthSync(), bytes.length);
      expect(File(staged).readAsBytesSync(), bytes);
      expect(h.chunkHashes, expectedIds(size));
    });
  });
}
