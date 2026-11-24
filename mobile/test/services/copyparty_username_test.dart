import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/config/copyparty_config.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';

const _host = 'https://cp.example.test';

({CopypartyUploaderService service, List<http.BaseRequest> seen}) _setup({String username = ''}) {
  final seen = <http.BaseRequest>[];
  final client = MockClient((req) async {
    seen.add(req);
    return http.Response(jsonEncode({'files': <Object>[]}), 200);
  });
  return (service: CopypartyUploaderService(client: client, username: username), seen: seen);
}

String _basic(String user, String password) => 'Basic ${base64.encode(utf8.encode('$user:$password'))}';

void main() {
  group('copyparty credentials', () {
    test('without a username the password rides in ?pw= and nothing else changes', () async {
      final t = _setup();
      await t.service.listUploadFolder(_host, '/Trips', 'hunter2');
      expect(t.seen.single.url.queryParameters['pw'], 'hunter2');
      expect(t.seen.single.headers.containsKey('authorization'), isFalse);
    });

    test('with a username the credentials go in an HTTP Basic header and NOT in the URL', () async {
      final t = _setup(username: 'sam');
      await t.service.listUploadFolder(_host, '/Trips', 'hunter2');
      expect(t.seen.single.headers['authorization'], _basic('sam', 'hunter2'));
      expect(t.seen.single.url.queryParameters.containsKey('pw'), isFalse);
      expect(t.seen.single.url.queryParameters.containsKey('ls'), isTrue);
    });

    test('a username is trimmed, and a password with ":" or non-ASCII characters survives', () async {
      final t = _setup(username: '  sam  ');
      await t.service.listUploadFolder(_host, '/Trips', 'pa:ss wörd');
      final header = t.seen.single.headers['authorization']!;
      expect(header, _basic('sam', 'pa:ss wörd'));
      final decoded = utf8.decode(base64.decode(header.substring('Basic '.length)));
      expect(decoded.split(':').first, 'sam');
      expect(decoded.substring(decoded.indexOf(':') + 1), 'pa:ss wörd');
    });

    test('a username with an empty password still authenticates as user:', () async {
      final t = _setup(username: 'sam');
      await t.service.listUploadFolder(_host, '/Trips', '');
      expect(t.seen.single.headers['authorization'], _basic('sam', ''));
    });

    test('deleting sends the same Basic header and no pw parameter', () async {
      final t = _setup(username: 'sam');
      await t.service.deleteFile(_host, '/Trips', 'a.insv', 'hunter2');
      expect(t.seen.single.method, 'DELETE');
      expect(t.seen.single.headers['authorization'], _basic('sam', 'hunter2'));
      expect(t.seen.single.url.queryParameters.containsKey('pw'), isFalse);
    });
  });

  group('connection test', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('cp_conn_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    // A scripted server: [ls] answers GET, [handshake] answers the up2k POST, [del] answers DELETE.
    ({CopypartyUploaderService service, List<http.BaseRequest> seen}) server({
      int ls = 200,
      int handshake = 200,
      int del = 200,
      String username = 'ian',
    }) {
      final seen = <http.BaseRequest>[];
      final client = MockClient((req) async {
        seen.add(req);
        if (req.method == 'GET') {
          return http.Response(jsonEncode({'files': <Object>[]}), ls);
        }
        if (req.method == 'POST') {
          // empty "hash" list = server already has the content = fully confirmed, no chunk upload needed
          return http.Response(jsonEncode({'wark': 'w' * 44, 'purl': '/ian/', 'hash': <String>[]}), handshake);
        }
        return http.Response('', del);
      });
      return (service: CopypartyUploaderService(client: client, username: username), seen: seen);
    }

    test('refuses to test a username with no password, without touching the network', () async {
      final t = server();
      final r = await t.service.testConnection(_host, '/ian', '', tempDir: tmp);
      expect(r.ok, isFalse);
      expect(r.message, contains('No password'));
      expect(t.seen, isEmpty);
    });

    test('success = authenticated read, then a real write, then cleanup — all with the credentials', () async {
      final t = server();
      final r = await t.service.testConnection(_host, '/ian', 'hunter2', tempDir: tmp);
      expect(r.ok, isTrue);
      expect(r.message, contains('write access to /ian'));
      expect(t.seen.map((q) => q.method), [
        'GET',
        'POST',
        'DELETE',
        'GET',
      ], reason: 'the last GET confirms the test file is gone');
      for (final q in t.seen) {
        expect(q.headers['authorization'], _basic('ian', 'hunter2'));
        expect(q.url.queryParameters.containsKey('pw'), isFalse);
      }
      expect(t.seen[2].url.path, startsWith('/ian/immich-connection-test-'));
      expect(tmp.listSync(), isEmpty, reason: 'the local temp file must be removed');
    });

    test('the password never appears in the result message', () async {
      final t = server(ls: 403);
      final r = await t.service.testConnection(_host, '/ian', 'hunter2', tempDir: tmp);
      expect(r.message, isNot(contains('hunter2')));
    });

    test('a 403 on the listing is reported as wrong credentials / no access, and no write is attempted', () async {
      final t = server(ls: 403);
      final r = await t.service.testConnection(_host, '/ian', 'wrong', tempDir: tmp);
      expect(r.ok, isFalse);
      expect(r.message, contains('Wrong username/password'));
      expect(r.message, contains('/ian'));
      expect(t.seen.map((q) => q.method), ['GET']);
    });

    test('readable but not writable is reported as no write access', () async {
      final t = server(handshake: 403);
      final r = await t.service.testConnection(_host, '/ian', 'hunter2', tempDir: tmp);
      expect(r.ok, isFalse);
      expect(r.message, contains('no write access to /ian'));
    });

    test('a missing path is reported as not found', () async {
      final t = server(ls: 404, handshake: 404);
      final r = await t.service.testConnection(_host, '/nope', 'hunter2', tempDir: tmp);
      expect(r.ok, isFalse);
      expect(r.message, contains('not found'));
    });

    test('a not-yet-created folder under a writable volume still passes (the upload creates it)', () async {
      final t = server(ls: 404);
      final r = await t.service.testConnection(_host, '/ian/new', 'hunter2', tempDir: tmp);
      expect(r.ok, isTrue);
    });

    test('write works but delete is refused: still ok, and the leftover file is named', () async {
      final t = server(del: 403);
      final r = await t.service.testConnection(_host, '/ian', 'hunter2', tempDir: tmp);
      expect(r.ok, isTrue);
      expect(r.message, contains('could not be deleted'));
      expect(r.message, contains('immich-connection-test-'));
    });

    test('without a username, a password still rides in ?pw= (original behaviour)', () async {
      final t = server(username: '');
      final r = await t.service.testConnection(_host, '/up', 'hunter2', tempDir: tmp);
      expect(r.ok, isTrue);
      expect(t.seen.first.url.queryParameters['pw'], 'hunter2');
      expect(t.seen.first.headers.containsKey('authorization'), isFalse);
    });
  });

  group('upload path for a username ("OK + set upload path")', () {
    test('a username becomes a single top-level folder', () {
      expect(uploadPathForUsername('ian'), '/ian');
    });

    test('whitespace and stray slashes are dropped', () {
      expect(uploadPathForUsername('  ian  '), '/ian');
      expect(uploadPathForUsername('/ian/'), '/ian');
    });

    test('no usable username gives no path', () {
      expect(uploadPathForUsername(''), '');
      expect(uploadPathForUsername('   '), '');
      expect(uploadPathForUsername('//'), '');
    });
  });
}
