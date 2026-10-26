import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';

const _file = 'VID_20261022_153357_00_035.insv';
const _url = 'https://cp.example.test/Asia2026/360%20pagoda%2022nd%20oct/$_file';

http.Response _listing(Map<String, int> files) => http.Response(
  jsonEncode({
    'files': [
      for (final e in files.entries) {'href': Uri.encodeComponent(e.key), 'sz': e.value},
    ],
  }),
  200,
);

/// Serves [files] for GET ?ls and records every DELETE; [deleteStatus] is the answer to DELETE.
({CopypartyUploaderService service, List<Uri> deletes}) _setup(Map<String, int> files, {int deleteStatus = 200}) {
  final deletes = <Uri>[];
  final client = MockClient((req) async {
    if (req.method == 'DELETE') {
      deletes.add(req.url);
      return http.Response('', deleteStatus);
    }
    return _listing(files);
  });
  return (service: CopypartyUploaderService(client: client), deletes: deletes);
}

void main() {
  group('verification state for a complete file plus a .partial', () {
    test('complete file + exact .PARTIAL is a "potential duplicate", not a failed upload', () {
      final v = CopypartyUploaderService.verificationFromListing({_file: 1000, '$_file.PARTIAL': 1000}, _file, 1000);
      expect(v.partialExists, VerifyState.yes);
      expect(v.looksLikeStrayPartial, isTrue);
      expect(v.hasStrayPartial, isTrue);
      expect(v.strayPartial, isFalse); // not hash-proven yet
    });

    test('a 0-byte placeholder + .PARTIAL is a genuine unfinished upload (not stray)', () {
      final v = CopypartyUploaderService.verificationFromListing({_file: 0, '$_file.PARTIAL': 500}, _file, 1000);
      expect(v.looksLikeStrayPartial, isFalse);
      expect(v.partialExists, VerifyState.yes);
    });

    test('only a .partial and no complete file is a genuine unfinished upload', () {
      final v = CopypartyUploaderService.verificationFromListing({'$_file.PARTIAL': 500}, _file, 1000);
      expect(v.looksLikeStrayPartial, isFalse);
    });

    test('a stray partial does not block "safe to delete" once the hash is freshly verified', () {
      final now = DateTime(2026, 10, 26, 12);
      const base = ServerFileVerification(
        filenamePresent: VerifyState.yes,
        sizeMatches: VerifyState.yes,
        partialExists: VerifyState.yes,
      );
      // before verification: not safe
      expect(base.safeToDeleteAt(now), isFalse);
      // verified + stray: safe, even if a later listing re-reports the partial
      final verified = base.copyWith(hashValidatedAt: now, strayPartial: true);
      expect(verified.safeToDeleteAt(now), isTrue);
      // a genuine partial (not stray) still blocks, even with a fresh hash stamp
      expect(base.copyWith(hashValidatedAt: now).safeToDeleteAt(now), isFalse);
      // a stale verification is not trusted
      expect(verified.safeToDeleteAt(now.add(const Duration(minutes: 11))), isFalse);
    });
  });

  group('removeStrayPartials', () {
    test('deletes exactly the .PARTIAL next to a complete file, with auth, in the right folder', () async {
      final t = _setup({_file: 1000, '$_file.PARTIAL': 1000, 'other.insv': 5});
      final r = await t.service.removeStrayPartials(fileUrl: _url, filename: _file, password: 'pw1');
      expect(r.removed, ['$_file.PARTIAL']);
      expect(r.failed, isEmpty);
      expect(t.deletes, hasLength(1));
      expect(t.deletes.single.pathSegments, ['Asia2026', '360 pagoda 22nd oct', '$_file.PARTIAL']);
      expect(t.deletes.single.queryParameters['pw'], 'pw1');
    });

    test('also removes the dot-prefixed form', () async {
      final t = _setup({_file: 1000, '.$_file.PARTIAL': 1000});
      final r = await t.service.removeStrayPartials(fileUrl: _url, filename: _file, password: '');
      expect(r.removed, ['.$_file.PARTIAL']);
      expect(t.deletes.single.queryParameters, isEmpty);
    });

    test('NEVER touches the complete file, other files, or a suffixed partial that may be another upload', () async {
      final t = _setup({
        _file: 1000,
        '$_file.PARTIAL': 1000,
        '$_file-1793000000-abc.insv.PARTIAL': 400,
        'VID_20261022_153357_00_036.insv.PARTIAL': 400,
      });
      final r = await t.service.removeStrayPartials(fileUrl: _url, filename: _file, password: 'x');
      expect(r.removed, ['$_file.PARTIAL']);
      expect(t.deletes.map((u) => u.pathSegments.last), ['$_file.PARTIAL']);
    });

    test('does nothing when the complete file is not on the server (the partial may be the only copy)', () async {
      final t = _setup({'$_file.PARTIAL': 1000});
      final r = await t.service.removeStrayPartials(fileUrl: _url, filename: _file, password: 'x');
      expect(r.skipped, isNotNull);
      expect(t.deletes, isEmpty);
    });

    test('does nothing when the "complete" file is a 0-byte placeholder', () async {
      final t = _setup({_file: 0, '$_file.PARTIAL': 800});
      final r = await t.service.removeStrayPartials(fileUrl: _url, filename: _file, password: 'x');
      expect(r.skipped, isNotNull);
      expect(t.deletes, isEmpty);
    });

    test('a refused delete (no permission) is reported, not thrown', () async {
      final t = _setup({_file: 1000, '$_file.PARTIAL': 1000}, deleteStatus: 403);
      final r = await t.service.removeStrayPartials(fileUrl: _url, filename: _file, password: 'x');
      expect(r.removed, isEmpty);
      expect(r.failed.single, contains('403'));
    });

    test('a listing failure is reported, not thrown, and nothing is deleted', () async {
      final deletes = <Uri>[];
      final service = CopypartyUploaderService(
        client: MockClient((req) async {
          if (req.method == 'DELETE') {
            deletes.add(req.url);
          }
          return http.Response('boom', 500);
        }),
      );
      final r = await service.removeStrayPartials(fileUrl: _url, filename: _file, password: 'x');
      expect(r.skipped, isNotNull);
      expect(deletes, isEmpty);
    });

    test('nothing to do when there is no partial', () async {
      final t = _setup({_file: 1000});
      final r = await t.service.removeStrayPartials(fileUrl: _url, filename: _file, password: 'x');
      expect(r.nothingToDo, isTrue);
      expect(t.deletes, isEmpty);
    });
  });
}
