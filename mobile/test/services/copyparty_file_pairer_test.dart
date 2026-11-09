import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/services/copyparty/copyparty_file_pairer.dart';

FileInfo _f(String name, {String dir = '/sd/DCIM/360 18th oct', int size = 1000}) =>
    FileInfo(path: '$dir/$name', name: name, sizeBytes: size, lastModifiedMs: 0);

List<String> _names(UploadSet s) => s.files.map((f) => f.filename).toList()..sort();

void main() {
  const pairer = CopypartyFilePairer();

  group('Insta360 clips', () {
    test('LRV preview and INSV recording of the same capture form ONE set despite different type fields', () {
      final sets = pairer.pairFiles([_f('VID_20261018_072236_00_004.insv'), _f('LRV_20261018_072236_01_004.lrv')]);
      expect(sets, hasLength(1));
      expect(_names(sets.single), ['LRV_20261018_072236_01_004.lrv', 'VID_20261018_072236_00_004.insv']);
    });

    test('both lenses (00 and 10) and the preview all land in the same set', () {
      final sets = pairer.pairFiles([
        _f('VID_20261018_072236_00_004.insv'),
        _f('VID_20261018_072236_10_004.insv'),
        _f('LRV_20261018_072236_01_004.lrv'),
      ]);
      expect(sets, hasLength(1));
      expect(sets.single.files, hasLength(3));
    });

    test('different sequence numbers stay separate captures', () {
      final sets = pairer.pairFiles([
        _f('VID_20261018_072236_00_003.insv'),
        _f('LRV_20261018_072236_01_003.lrv'),
        _f('VID_20261018_072236_00_004.insv'),
        _f('LRV_20261018_072236_01_004.lrv'),
      ]);
      expect(sets, hasLength(2));
      expect(sets.map((s) => s.files.length), everyElement(2));
    });

    test('different recording times stay separate even with the same sequence number', () {
      final sets = pairer.pairFiles([
        _f('VID_20261018_072236_00_004.insv'),
        _f('LRV_20261018_072236_01_004.lrv'),
        _f('VID_20261018_091500_00_004.insv'),
        _f('LRV_20261018_091500_01_004.lrv'),
      ]);
      expect(sets, hasLength(2));
    });

    test('photos (IMG_ .insp) pair with their other-lens file too', () {
      final sets = pairer.pairFiles([_f('IMG_20261018_072236_00_001.insp'), _f('IMG_20261018_072236_10_001.insp')]);
      expect(sets, hasLength(1));
      expect(sets.single.files, hasLength(2));
    });

    test('same capture in different folders is not merged', () {
      final sets = pairer.pairFiles([
        _f('VID_20261018_072236_00_004.insv', dir: '/sd/a'),
        _f('LRV_20261018_072236_01_004.lrv', dir: '/sd/b'),
      ]);
      expect(sets, hasLength(2));
    });
  });

  group('existing behaviour is unchanged', () {
    test('DJI/GoPro style LRV_x + VID_x still pair by stem', () {
      final sets = pairer.pairFiles([_f('LRV_0001.lrv'), _f('VID_0001.mp4')]);
      expect(sets, hasLength(1));
      expect(sets.single.files, hasLength(2));
    });

    test('a lone non-trigger file does not create a set', () {
      expect(pairer.pairFiles([_f('VID_20261018_072236_00_004.mp4')]), isEmpty);
    });

    test('normalise: non-Insta360 names keep the old prefix stripping', () {
      expect(pairer.normalise('LRV_0001.lrv'), '0001');
      expect(pairer.normalise('IMG_1234.JPG'), 'img_1234');
    });

    test('normalise: Insta360 names drop the type/lens field', () {
      expect(pairer.normalise('VID_20261018_072236_00_004.insv'), '20261018_072236_004');
      expect(pairer.normalise('LRV_20261018_072236_01_004.lrv'), '20261018_072236_004');
    });
  });
}
