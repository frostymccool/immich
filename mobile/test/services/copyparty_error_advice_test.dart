import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/services/copyparty/copyparty_error_advice.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';

const _host = 'https://cp.example.test:3923';
final _at = DateTime.utc(2026, 11, 24, 20, 50, 7);

UploadFailureAdvice _classify(Object e) => UploadFailureAdvice.classify(e, hostUrl: _host, uploadPath: '/ian', at: _at);

void main() {
  group('every failure says what the user must do', () {
    test('no connection → check home Wi-Fi or VPN, then Retry', () {
      final a = _classify(const SocketException('Connection refused'));
      expect(a.kind, UploadFailureKind.unreachable);
      expect(
        a.action,
        "Can't reach cp.example.test:3923. Check you are on home Wi-Fi, or that the VPN is connected, then tap Retry.",
      );
      expect(a.isConnectionProblem, isTrue);
    });

    test('a stalled handshake is a timeout with the same instruction', () {
      final a = _classify(const CopypartyUploadException('handshake stalled (no response in 60s)', stalled: true));
      expect(a.kind, UploadFailureKind.timeout);
      expect(a.action, contains('home Wi-Fi'));
      expect(a.isConnectionProblem, isTrue);
    });

    test('a dropped connection (ClientException) counts as unreachable', () {
      expect(
        _classify(http.ClientException('Connection closed before full header was received')).kind,
        UploadFailureKind.unreachable,
      );
      expect(_classify(TimeoutException('slow')).kind, UploadFailureKind.timeout);
    });

    test('401 and 403 → fix the login or write access in settings', () {
      for (final code in [401, 403]) {
        final a = _classify(CopypartyUploadException('Handshake failed: HTTP $code\nnope', statusCode: code));
        expect(a.kind, UploadFailureKind.auth);
        expect(a.action, contains('no write access to /ian'));
        expect(a.action, contains('Test Connection'));
        expect(a.isConnectionProblem, isFalse);
      }
    });

    test('404, 5xx and TLS each get their own instruction', () {
      expect(_classify(const CopypartyUploadException('x', statusCode: 404)).action, contains('was not found'));
      final s = _classify(const CopypartyUploadException('Chunk #3 upload failed: HTTP 503 (wark=w)'));
      expect(s.kind, UploadFailureKind.server, reason: 'the status is read from older messages too');
      expect(s.action, contains('(HTTP 503)'));
      final t = _classify(const HandshakeException('CERTIFICATE_VERIFY_FAILED'));
      expect(t.kind, UploadFailureKind.tls);
      expect(t.action, contains('Allow self-signed certificate'));
    });

    test('a stale partial keeps its own, already actionable, message', () {
      final a = _classify(
        const CopypartyUploadException(
          'A stale/incomplete upload for "a.mp4" already exists on the server. Remove that partial, then retry.',
          statusCode: 422,
        ),
      );
      expect(a.kind, UploadFailureKind.stalePartial);
      expect(a.action, startsWith('A stale/incomplete upload'));
    });

    test('the detail line has type, URL, local and UTC time, and the raw error, for the server logs', () {
      final a = _classify(const CopypartyUploadException('handshake stalled (no response in 60s)', stalled: true));
      expect(a.detail, startsWith('no response (timeout) · https://cp.example.test:3923/ian · '));
      expect(a.detail, contains('(2026-11-24T20:50:07Z)'));
      expect(a.detail, endsWith('handshake stalled (no response in 60s)'));
      expect(a.userText, '${a.action}\n${a.detail}');
    });

    test('a password in the host URL never reaches the message', () {
      final a = UploadFailureAdvice.classify(
        const SocketException('no route'),
        hostUrl: 'https://cp.example.test/?pw=hunter2',
        uploadPath: '/ian',
      );
      expect(a.userText, isNot(contains('hunter2')));
    });
  });

  group('preflight: one quick check before a batch', () {
    CopypartyUploaderService service(Future<http.Response> Function(http.Request) handler) =>
        CopypartyUploaderService(client: MockClient(handler), username: 'ian');

    test('a reachable server with an accepted login passes (and a missing folder is fine)', () async {
      for (final code in [200, 404]) {
        final s = service((_) async => http.Response(jsonEncode({'files': <Object>[]}), code));
        expect(await s.preflight(_host, '/ian', 'pw'), isNull);
      }
    });

    test('a refused login stops the batch with the settings instruction', () async {
      final s = service((_) async => http.Response('forbidden', 403));
      final a = await s.preflight(_host, '/ian', 'pw');
      expect(a?.kind, UploadFailureKind.auth);
    });

    test('no route to the server is reported, never thrown', () async {
      final s = service((_) async => throw const SocketException('No route to host'));
      final a = await s.preflight(_host, '/ian', 'pw');
      expect(a?.kind, UploadFailureKind.unreachable);
      expect(a?.isConnectionProblem, isTrue);
    });
  });

  group('Test Connection cleans up after itself', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('cp_advice_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a test file still listed after the DELETE is reported by name', () async {
      String? uploaded;
      var deleted = false;
      final client = MockClient((req) async {
        if (req.method == 'POST') {
          uploaded = (jsonDecode(req.body) as Map)['name'] as String;
          return http.Response(jsonEncode({'wark': 'w' * 44, 'purl': '/ian/', 'hash': <String>[]}), 200);
        }
        if (req.method == 'DELETE') {
          deleted = true;
          return http.Response('', 200);
        }
        // The server still lists the file after a "successful" delete.
        final files = deleted && uploaded != null
            ? [
                {'href': uploaded, 'sz': 47},
              ]
            : <Object>[];
        return http.Response(jsonEncode({'files': files}), 200);
      });
      final r = await CopypartyUploaderService(
        client: client,
        username: 'ian',
      ).testConnection(_host, '/ian', 'pw', tempDir: tmp);
      expect(r.ok, isTrue, reason: 'write access itself works');
      expect(r.message, contains('could not be deleted'));
      expect(uploaded, isNotNull);
      expect(r.message, contains('$uploaded'));
    });
  });
}
