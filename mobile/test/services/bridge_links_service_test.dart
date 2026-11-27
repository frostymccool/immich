import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/services/copyparty/bridge_links.service.dart';

void main() {
  const bridge = 'https://bridge.example.test';
  const token = 'fake-immich-token';

  http.Response json(int code, Object body) =>
      http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json'});

  test('inspect sends the link with the Immich login and reads the album', () async {
    late http.Request seen;
    final service = BridgeLinksService(
      client: MockClient((r) async {
        seen = r;
        return json(200, {
          'source': 'google-photos',
          'title': 'Beach day',
          'photos': 12,
          'videos': 3,
          'days': ['2026-07-01', '2026-07-02'],
          'suggestions': ['Seaside 2026-07-01', 'Beach day 2026-07-01', 'Beach day'],
          'folder': 'alex-1234',
        });
      }),
    );
    final album = await service.inspect(bridge, token, ' https://photos.app.goo.gl/abc ');
    expect(seen.method, 'POST');
    expect(seen.url.toString(), '$bridge/api/links/inspect');
    expect(seen.headers['X-Immich-Token'], token);
    expect(jsonDecode(seen.body), {'url': 'https://photos.app.goo.gl/abc'});
    expect(album.photos, 12);
    expect(album.videos, 3);
    expect(album.suggestions.first, 'Seaside 2026-07-01');
    expect(album.folder, 'alex-1234');
  });

  test('start sends the chosen name; a blank name lets the bridge choose', () async {
    final bodies = <Object?>[];
    final service = BridgeLinksService(
      client: MockClient((r) async {
        bodies.add(jsonDecode(r.body));
        return json(202, {'id': 'j1', 'name': 'Seaside', 'state': 'running', 'total': 15});
      }),
    );
    final job = await service.start(bridge, token, 'https://photos.app.goo.gl/abc', 'Seaside');
    await service.start(bridge, token, 'https://photos.app.goo.gl/abc', '  ');
    expect(bodies[0], {'url': 'https://photos.app.goo.gl/abc', 'name': 'Seaside'});
    expect(bodies[1], {'url': 'https://photos.app.goo.gl/abc'});
    expect(job.running, isTrue);
    expect(job.total, 15);
  });

  test('jobs are read, including what is still on the NAS', () async {
    final service = BridgeLinksService(
      client: MockClient(
        (r) async => json(200, {
          'jobs': [
            {'id': 'j1', 'name': 'Seaside', 'state': 'done', 'total': 15, 'done': 14, 'skipped': 1, 'kept_on_nas': 2},
          ],
        }),
      ),
    );
    final jobs = await service.jobs(bridge, token);
    expect(jobs.single.name, 'Seaside');
    expect(jobs.single.keptOnNas, 2);
    expect(jobs.single.running, isFalse);
  });

  test('the Immich login is never sent over plain http, nor without a login', () async {
    var calls = 0;
    final service = BridgeLinksService(
      client: MockClient((r) async {
        calls++;
        return json(200, {});
      }),
    );
    await expectLater(service.jobs('http://bridge.example.test', token), throwsA(isA<BridgeLinkException>()));
    await expectLater(service.jobs(bridge, null), throwsA(isA<BridgeLinkException>()));
    await expectLater(service.jobs('', token), throwsA(isA<BridgeLinkException>()));
    expect(calls, 0);
  });

  test('bridge refusals become plain sentences', () async {
    Future<String> messageFor(int code, Object body) async {
      final service = BridgeLinksService(client: MockClient((r) async => json(code, body)));
      try {
        await service.inspect(bridge, token, 'https://example.test/x');
        return 'no error';
      } on BridgeLinkException catch (e) {
        return e.message;
      }
    }

    expect(await messageFor(400, {'error': 'paste a Google Photos shared album link'}), startsWith('Paste a Google'));
    expect(
      await messageFor(409, {'error': 'the bridge can only read the upload folders'}),
      startsWith('The bridge can'),
    );
    expect(await messageFor(404, {'error': 'not found'}), contains('0.10.0'));
    expect(await messageFor(404, {'error': 'not a bridge user'}), contains('not set up'));
    expect(await messageFor(401, {'error': 'x'}), contains('Immich login'));
    expect(await messageFor(503, {'error': 'immich unreachable'}), contains('cannot reach Immich'));
  });

  group('link page errors say what really failed', () {
    // Bug: the link page said "The bridge could not be reached" while Test bridge worked. The page had closed its
    // own connection (an autoDispose provider read without watching), and every failure was reported as the
    // network.
    test('a closed connection is reported as an app problem, not the network', () async {
      // A real connection, closed the way the provider closed it; a closed one refuses before any network use.
      final service = BridgeLinksService();
      service.dispose();
      await expectLater(
        service.jobs(bridge, token),
        throwsA(isA<BridgeLinkException>().having((e) => e.message, 'message', contains('app problem'))),
      );
    });

    test('a connection that stays open keeps working for every request', () async {
      var calls = 0;
      final service = BridgeLinksService(
        client: MockClient((r) async {
          calls++;
          return json(200, {'jobs': []});
        }),
      );
      await service.jobs(bridge, token);
      await service.jobs(bridge, token);
      expect(calls, 2);
    });

    test('each kind of failure has its own words', () {
      expect(describeTransportError(TimeoutException('x')), contains('too long'));
      expect(describeTransportError(const SocketException('refused')), contains('home network or VPN'));
      expect(describeTransportError(const HandshakeException('bad cert')), contains('certificate'));
      expect(describeTransportError(Exception('odd')), contains('could not talk to the bridge'));
    });
  });

  group('Test bridge checks link imports too', () {
    test('working', () async {
      final r = await testBridgeLinks(
        bridge,
        token,
        client: MockClient(
          (r) async => json(200, {
            'jobs': [
              {'id': 'j', 'name': 'n', 'state': 'done'},
            ],
          }),
        ),
      );
      expect(r.ok, isTrue);
      expect(r.message, contains('working (1 recent import)'));
    });

    test('a refusal is named', () async {
      final r = await testBridgeLinks(
        bridge,
        token,
        client: MockClient((r) async => json(404, {'error': 'not found'})),
      );
      expect(r.ok, isFalse);
      expect(r.message, contains('0.10.0'));
    });

    test('never over plain http', () async {
      final r = await testBridgeLinks('http://bridge.example.test', token);
      expect(r.ok, isFalse);
      expect(r.message, contains('https'));
    });
  });
}
