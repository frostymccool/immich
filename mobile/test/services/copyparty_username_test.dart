import 'dart:convert';

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

    test('the connection test authenticates with the username too', () async {
      final t = _setup(username: 'sam');
      expect(await t.service.testConnection(_host, 'hunter2'), isNull);
      expect(t.seen.single.headers['authorization'], _basic('sam', 'hunter2'));
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
