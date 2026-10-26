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
      expect(ImmichBridgeStatusService.normalizeBaseUrl('192.168.5.21:8099')?.toString(), 'http://192.168.5.21:8099');
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

  group('fetch parses a healthy bridge', () {
    test('reads version, counts, queue and recent activity', () async {
      final service = _service(
        MockClient((request) async {
          if (request.url.path == '/healthz') {
            return _json({'ok': true, 'version': '0.1.0'});
          }
          expect(request.url.path, '/status');
          return _json({
            'counts': {'imported': 12, 'duplicate': 3, 'failed': 1, 'skipped': 2},
            'queue': 4,
            'watch_dirs': ['/w/Australia'],
            'priority_dirs': ['/w/Australia/Asia2026'],
            'recent': [
              {
                'path': '/w/uploads/trip/IMG_0001.JPG',
                'status': 'imported',
                'asset_id': 'abc',
                'error': null,
                'attempts': 0,
                'updated_at': 1792576800.5,
              },
              {
                'path': '/w/uploads/IMG_0002.MOV',
                'status': 'failed',
                'error': 'upload failed: HTTP 500',
                'attempts': 2,
                'updated_at': 1792576700,
              },
              {'bogus': true},
            ],
          });
        }),
      );

      final status = await service.fetch('http://bridge:8099/');
      expect(status.health, BridgeHealth.running);
      expect(status.baseUrl.toString(), 'http://bridge:8099/');
      expect(status.version, '0.1.0');
      expect(status.imported, 12);
      expect(status.duplicates, 3);
      expect(status.failed, 1);
      expect(status.queue, 4);
      expect(status.watchDirs, ['/w/Australia']);
      expect(status.priorityDirs, ['/w/Australia/Asia2026']);
      expect(status.recent, hasLength(2));
      expect(status.recent.first.fileName, 'IMG_0001.JPG');
      expect(status.recent.last.error, 'upload failed: HTTP 500');
      expect(status.lastActivity, DateTime.fromMillisecondsSinceEpoch(1792576800500));
    });

    test('status failure still reports running (health alone is enough)', () async {
      final service = _service(
        MockClient((request) async {
          if (request.url.path == '/healthz') {
            return _json({'ok': true, 'version': '0.1.0'});
          }
          return _json({'error': 'boom'}, 500);
        }),
      );
      final status = await service.fetch('http://bridge:8099');
      expect(status.health, BridgeHealth.running);
      expect(status.version, '0.1.0');
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
      await service.fetch('https://example.com/bridge/');
      expect(seen, ['/bridge/healthz', '/bridge/status']);
    });
  });
}
