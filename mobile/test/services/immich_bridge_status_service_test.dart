import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/services/copyparty/immich_bridge_status.service.dart';

http.Response _json(Object body, [int code = 200]) =>
    http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json'});

ImmichBridgeStatusService _service(MockClient client) =>
    ImmichBridgeStatusService(client: client, now: () => DateTime(2026, 10, 21, 12));

void main() {
  group('normalizeBaseUrl', () {
    test('adds http:// when the scheme is missing', () {
      expect(ImmichBridgeStatusService.normalizeBaseUrl('192.168.1.50:8099')?.toString(), 'http://192.168.1.50:8099');
    });

    test('rejects blank and non-http(s) values', () {
      expect(ImmichBridgeStatusService.normalizeBaseUrl(''), isNull);
      expect(ImmichBridgeStatusService.normalizeBaseUrl('   '), isNull);
      expect(ImmichBridgeStatusService.normalizeBaseUrl('ftp://host'), isNull);
      expect(ImmichBridgeStatusService.normalizeBaseUrl('http://'), isNull);
    });
  });

  group('fetch never throws and never touches the network when unconfigured', () {
    test('blank URL is disabled without making a request', () async {
      var calls = 0;
      final service = _service(
        MockClient((_) async {
          calls++;
          return _json({});
        }),
      );
      final status = await service.fetch('');
      expect(status.health, BridgeHealth.disabled);
      expect(calls, 0);
    });

    test('garbage URL is reported as invalid, not thrown', () async {
      final status = await _service(MockClient((_) async => _json({}))).fetch('ftp://nope');
      expect(status.health, BridgeHealth.invalidUrl);
    });

    test('connection failure maps to unreachable', () async {
      final service = _service(MockClient((_) async => throw http.ClientException('connection refused')));
      expect((await service.fetch('http://bridge:8099')).health, BridgeHealth.unreachable);
    });

    test('timeout maps to unreachable', () async {
      final service = _service(MockClient((_) async => throw TimeoutException('slow')));
      expect((await service.fetch('http://bridge:8099')).health, BridgeHealth.unreachable);
    });

    test('non-200 health response is unreachable', () async {
      final service = _service(MockClient((_) async => _json({'ok': true}, 503)));
      expect((await service.fetch('http://bridge:8099')).health, BridgeHealth.unreachable);
    });

    test('garbage (non-JSON) response is unreachable, not a crash', () async {
      final service = _service(MockClient((_) async => http.Response('<html>nginx</html>', 200)));
      expect((await service.fetch('http://bridge:8099')).health, BridgeHealth.unreachable);
    });

    test('health payload without ok:true is unreachable', () async {
      final service = _service(MockClient((_) async => _json({'ok': false})));
      expect((await service.fetch('http://bridge:8099')).health, BridgeHealth.unreachable);
    });
  });

  group('per-person status (/status/me)', () {
    const token = 'test-immich-token';
    Map<String, Object?> meBody() => {
      'me': {'bridge_user': 'alice', 'name': 'Alice'},
      'immich_user': {'id': 'u1', 'name': 'Alice', 'email': 'alice@example.com'},
      'counts': {'imported': 12, 'duplicate': 3, 'failed': 1, 'skipped': 2},
      'queue': 4,
      'watch_dirs': ['/w/alice'],
      'priority_dirs': ['/w/alice/Phone'],
      'recent': [
        {
          'path': '/w/alice/trip/IMG_0001.JPG',
          'status': 'imported',
          'asset_id': 'abc',
          'error': null,
          'attempts': 0,
          'updated_at': 1792576800.5,
        },
        {
          'path': '/w/alice/IMG_0002.MOV',
          'status': 'failed',
          'error': 'upload failed: HTTP 500',
          'attempts': 2,
          'updated_at': 1792576700,
        },
        {'bogus': true},
      ],
    };

    test('reads only this person\'s status, sending the token in a header over https', () async {
      final seen = <http.Request>[];
      final service = _service(
        MockClient((request) async {
          seen.add(request);
          if (request.url.path == '/healthz') {
            return _json({'ok': true, 'version': '0.8.0'});
          }
          expect(request.url.path, '/status/me');
          return _json(meBody());
        }),
      );

      final status = await service.fetch('https://bridge.example.com/', immichToken: token);
      expect(status.health, BridgeHealth.running);
      expect(status.access, BridgeAccess.signedIn);
      expect(status.signedInAs, 'Alice');
      expect(status.accessMessage, 'Signed in as Alice');
      expect(status.version, '0.8.0');
      expect(status.imported, 12);
      expect(status.duplicates, 3);
      expect(status.failed, 1);
      expect(status.queue, 4);
      expect(status.watchDirs, ['/w/alice']);
      expect(status.priorityDirs, ['/w/alice/Phone']);
      expect(status.recent, hasLength(2));
      expect(status.recent.first.fileName, 'IMG_0001.JPG');
      expect(status.recent.last.error, 'upload failed: HTTP 500');
      expect(status.lastActivity, DateTime.fromMillisecondsSinceEpoch(1792576800500));

      expect(seen.map((r) => r.url.path), ['/healthz', '/status/me'], reason: 'the open /status is never read');
      expect(seen.first.headers.containsKey('X-Immich-Token'), isFalse, reason: 'no token on the health check');
      expect(seen.last.headers['X-Immich-Token'], token);
      for (final r in seen) {
        expect(r.url.toString(), isNot(contains(token)), reason: 'the token never goes into a URL');
      }
    });

    test('plain http never sends the token and shows no personal detail', () async {
      final seen = <http.Request>[];
      final service = _service(
        MockClient((request) async {
          seen.add(request);
          return _json({'ok': true, 'version': '0.8.0'});
        }),
      );
      final status = await service.fetch('http://192.168.1.50:8099', immichToken: token);
      expect(status.health, BridgeHealth.running);
      expect(status.access, BridgeAccess.needsHttps);
      expect(status.imported, 0);
      expect(status.watchDirs, isEmpty);
      expect(seen.map((r) => r.url.path), ['/healthz']);
      expect(seen.any((r) => r.headers.containsKey('X-Immich-Token')), isFalse);
    });

    test('no Immich login means no personal request', () async {
      final seen = <String>[];
      final service = _service(
        MockClient((request) async {
          seen.add(request.url.path);
          return _json({'ok': true});
        }),
      );
      final status = await service.fetch('https://bridge.example.com', immichToken: null);
      expect(status.access, BridgeAccess.notSignedIn);
      expect(seen, ['/healthz']);
    });

    Future<BridgeStatus> answer(int code, Object body) => _service(
      MockClient(
        (request) async => request.url.path == '/healthz' ? _json({'ok': true, 'version': '0.8.0'}) : _json(body, code),
      ),
    ).fetch('https://bridge.example.com', immichToken: token);

    test('401 means the login was not accepted', () async {
      final status = await answer(401, {'error': 'token not accepted'});
      expect(status.access, BridgeAccess.tokenRejected);
      expect(status.imported, 0);
    });

    test('404 "not a bridge user" is told apart from an older bridge', () async {
      expect((await answer(404, {'error': 'not a bridge user'})).access, BridgeAccess.notBridgeUser);
      expect((await answer(404, {'error': 'not found'})).access, BridgeAccess.bridgeTooOld);
    });

    test('503 means Immich is unreachable, try later (not signed out)', () async {
      expect((await answer(503, {'error': 'immich unreachable'})).access, BridgeAccess.immichUnreachable);
    });

    test('other failures still report the bridge as running, with no personal detail', () async {
      final status = await answer(500, {'error': 'boom'});
      expect(status.health, BridgeHealth.running);
      expect(status.access, BridgeAccess.failed);
      expect(status.recent, isEmpty);
    });

    test('preserves a reverse-proxy base path', () async {
      final seen = <String>[];
      final service = _service(
        MockClient((request) async {
          seen.add(request.url.path);
          return request.url.path.endsWith('/healthz') ? _json({'ok': true}) : _json({'counts': {}, 'queue': 0});
        }),
      );
      await service.fetch('https://example.com/bridge/', immichToken: token);
      expect(seen, ['/bridge/healthz', '/bridge/status/me']);
    });
  });
}
