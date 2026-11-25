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
      expect(originalsKeptNotice(r.reason!), contains('Every original is kept'));
    });

    test('the up-front check reports the folder as not deletable', () async {
      final d = CopypartySourceDeleter(android: true, treeCanDelete: (_) async => false);
      expect(await d.deleteBlockedReason(dir.path), isNotNull);
      expect(dir.listSync().map((e) => e.path.split('/').last), ['a.mp4'], reason: 'no probe file is left behind');
    });

    test('a writable folder permission makes it deletable without probing', () async {
      final d = CopypartySourceDeleter(android: true, treeCanDelete: (_) async => true);
      expect(await d.deleteBlockedReason(dir.path), isNull);
    });
  });

  test('the up-front check on a writable folder leaves nothing behind', () async {
    final d = CopypartySourceDeleter(android: false);
    expect(await d.deleteBlockedReason(dir.path), isNull);
    expect(dir.listSync(), isEmpty);
  });

  group('the reason is said in plain words with the right fix', () {
    test('a read-only card says so and points at the lock switch and repair, not at permissions', () {
      final x = DeleteFailureExplanation.of(
        'Read-only file system, errno = 30; with the folder permission: the storage provider refused the delete',
      );
      expect(x.cause, 'The memory card is read-only (write-protected), so nothing on it can be deleted.');
      expect(x.action, contains('lock switch'));
      expect(x.action, contains('Do not format it'));
      expect(originalsKeptNotice(x.detail), startsWith('The memory card is read-only'));
      expect(originalsKeptNotice(x.detail), contains('(System message: Read-only file system'));
    });

    test('a missing folder permission says to pick the folder again', () {
      final x = DeleteFailureExplanation.of(
        'Permission denied; with the folder permission: no folder permission covers this file (pick the folder again in Import)',
      );
      expect(x.cause, 'Android has not given the app permission to delete on this card.');
      expect(x.action, contains('pick the card folder again'));
    });

    test('a plain permission refusal', () {
      expect(
        DeleteFailureExplanation.of('Permission denied, errno = 13').cause,
        contains('refused the app permission'),
      );
    });

    test('anything else still says what to do', () {
      final x = DeleteFailureExplanation.of('something odd');
      expect(x.action, contains('Save log'));
      expect(x.detail, 'something odd');
    });
  });
}
