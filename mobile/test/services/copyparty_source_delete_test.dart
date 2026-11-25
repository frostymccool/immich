import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/services/copyparty/copyparty_source_delete.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('cp_srcdel_'));
  tearDown(() {
    if (dir.existsSync()) {
      Process.runSync('chmod', ['-R', 'u+w', dir.path]);
      dir.deleteSync(recursive: true);
    }
  });

  test('a plain delete that works never touches the folder permission', () async {
    final f = File('${dir.path}/a.mp4')..writeAsStringSync('x');
    var treeCalls = 0;
    final d = CopypartySourceDeleter(
      android: true,
      treeDelete: (_) async {
        treeCalls++;
        return {'ok': true};
      },
    );
    expect((await d.delete(f.path)).ok, isTrue);
    expect(f.existsSync(), isFalse);
    expect(treeCalls, 0);
  });

  group('when the card refuses a plain delete', () {
    late File f;
    setUp(() {
      f = File('${dir.path}/a.mp4')..writeAsStringSync('x');
      Process.runSync('chmod', ['a-w', dir.path]); // read-only folder: the plain delete fails
    });

    test('it deletes through the folder permission', () async {
      String? asked;
      final d = CopypartySourceDeleter(
        android: true,
        treeDelete: (path) async {
          asked = path;
          Process.runSync('chmod', ['u+w', dir.path]);
          f.deleteSync(); // what the storage provider does
          return {'ok': true};
        },
      );
      expect((await d.delete(f.path)).ok, isTrue);
      expect(asked, f.path);
    });

    test('if both fail, the original stays and both reasons are reported in full', () async {
      final d = CopypartySourceDeleter(
        android: true,
        treeDelete: (_) async => {'ok': false, 'error': 'no folder permission'},
      );
      final r = await d.delete(f.path);
      expect(r.ok, isFalse);
      expect(f.existsSync(), isTrue);
      expect(r.reason, contains('with the folder permission: no folder permission'));
      expect(originalsKeptNotice(r.reason!), contains('every original is kept'));
    });

    test('the up-front check reports the folder as not deletable', () async {
      final d = CopypartySourceDeleter(android: true, treeCanDelete: (_) async => false);
      expect(await d.canDeleteIn(dir.path), isFalse);
      expect(dir.listSync().map((e) => e.path.split('/').last), ['a.mp4'], reason: 'no probe file is left behind');
    });

    test('a writable folder permission makes it deletable without probing', () async {
      final d = CopypartySourceDeleter(android: true, treeCanDelete: (_) async => true);
      expect(await d.canDeleteIn(dir.path), isTrue);
    });
  });

  test('the up-front check on a writable folder leaves nothing behind', () async {
    final d = CopypartySourceDeleter(android: false);
    expect(await d.canDeleteIn(dir.path), isTrue);
    expect(dir.listSync(), isEmpty);
  });
}
