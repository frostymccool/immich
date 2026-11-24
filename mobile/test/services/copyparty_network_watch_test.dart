import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/services/copyparty/copyparty_error_advice.dart';
import 'package:immich_mobile/services/copyparty/copyparty_network_watch.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';

const _host = 'https://192.168.1.50:3923';

UploadFailureAdvice _advice(Object e) => UploadFailureAdvice.classify(e, hostUrl: _host, uploadPath: '/ian');
final _down = _advice(const SocketException('No route to host'));
final _timeout = _advice(const CopypartyUploadException('handshake stalled', stalled: true));
final _refused = _advice(const CopypartyUploadException('x', statusCode: 403));

/// A fake clock that only moves when the waiter "sleeps".
class _Clock {
  DateTime now = DateTime(2026, 11, 24, 12);
  final slept = <Duration>[];
  Future<void> sleep(Duration d) async {
    slept.add(d);
    now = now.add(d);
  }
}

void main() {
  group('waiting for the network', () {
    test('backs off 5 s, 10 s, 30 s, then every 60 s, and resumes when the server answers', () async {
      final clock = _Clock();
      var probes = 0;
      final waiter = CopypartyNetworkWaiter(
        probe: () async => ++probes < 6 ? _down : null,
        now: () => clock.now,
        sleep: clock.sleep,
      );
      final checks = <int>[];
      final r = await waiter.wait(
        cancelled: Completer<void>().future,
        lastProblem: _down,
        onWaiting: (_, attempt) => checks.add(attempt),
      );
      expect(r.outcome, NetworkWaitOutcome.recovered);
      expect(clock.slept.map((d) => d.inSeconds), [5, 10, 30, 60, 60, 60]);
      expect(checks, [0, 1, 2, 3, 4, 5], reason: 'the UI is told before every check');
    });

    test('gives up after 30 minutes and hands back the last problem', () async {
      final clock = _Clock();
      final waiter = CopypartyNetworkWaiter(probe: () async => _timeout, now: () => clock.now, sleep: clock.sleep);
      final r = await waiter.wait(cancelled: Completer<void>().future, lastProblem: _down);
      expect(r.outcome, NetworkWaitOutcome.gaveUp);
      expect(r.advice?.kind, UploadFailureKind.timeout);
      final waited = clock.slept.fold<Duration>(Duration.zero, (a, b) => a + b);
      expect(waited, greaterThanOrEqualTo(CopypartyNetworkWaiter.giveUpAfter));
      expect(waited, lessThan(CopypartyNetworkWaiter.giveUpAfter + const Duration(minutes: 2)));
    });

    test('a server that answers but refuses the login needs the user, not more waiting', () async {
      final clock = _Clock();
      final waiter = CopypartyNetworkWaiter(probe: () async => _refused, now: () => clock.now, sleep: clock.sleep);
      final r = await waiter.wait(cancelled: Completer<void>().future, lastProblem: _down);
      expect(r.outcome, NetworkWaitOutcome.blocked);
      expect(r.advice?.kind, UploadFailureKind.auth);
      expect(clock.slept, hasLength(1));
    });

    test('Pause while waiting stops at once, without probing', () async {
      final cancel = Completer<void>()..complete();
      var probes = 0;
      final waiter = CopypartyNetworkWaiter(
        probe: () async {
          probes++;
          return _down;
        },
      );
      final r = await waiter.wait(cancelled: cancel.future, lastProblem: _down);
      expect(r.outcome, NetworkWaitOutcome.cancelled);
      expect(probes, 0);
    });

    test('a network change re-checks at once instead of sitting out the back-off', () async {
      final changes = StreamController<void>.broadcast();
      final never = Completer<void>();
      final waiter = CopypartyNetworkWaiter(
        probe: () async => null,
        networkChanges: changes.stream,
        sleep: (_) => never.future, // the back-off alone would wait forever
      );
      final result = waiter.wait(cancelled: Completer<void>().future, lastProblem: _down);
      await Future<void>.delayed(Duration.zero);
      changes.add(null);
      expect((await result).outcome, NetworkWaitOutcome.recovered);
      await changes.close();
    });
  });

  group('stall watchdog', () {
    test('a slow but working link (probe answers) is never aborted', () {
      expect(CopypartyStallWatch.shouldAbort(sinceProgress: const Duration(minutes: 5), probe: null), isFalse);
      expect(CopypartyStallWatch.shouldAbort(sinceProgress: const Duration(minutes: 5), probe: _refused), isFalse);
    });

    test('a connection that is gone is aborted at once', () {
      expect(CopypartyStallWatch.shouldAbort(sinceProgress: const Duration(seconds: 15), probe: _down), isTrue);
    });

    test('a probe timeout aborts only after 45 s with no bytes moving', () {
      expect(CopypartyStallWatch.shouldAbort(sinceProgress: const Duration(seconds: 30), probe: _timeout), isFalse);
      expect(CopypartyStallWatch.shouldAbort(sinceProgress: const Duration(seconds: 45), probe: _timeout), isTrue);
    });
  });

  group('what the banner says', () {
    test('LAN addresses are recognised', () {
      for (final h in ['https://192.168.1.50:3923', 'http://10.0.0.2', 'https://172.20.1.1', 'nas.lan', 'cp.local']) {
        expect(isLanHost(h), isTrue, reason: h);
      }
      for (final h in ['https://cp.example.com', 'https://8.8.8.8', 'https://172.32.0.1']) {
        expect(isLanHost(h), isFalse, reason: h);
      }
    });

    test('a VPN hint is added only when a VPN is on and the server is on the home network', () {
      final withVpn = waitingForNetworkMessage(_host, vpnOn: true);
      expect(withVpn, startsWith('Lost connection to 192.168.1.50:3923. Waiting to reconnect'));
      expect(withVpn, contains('Check you are on home Wi-Fi or the VPN is connected.'));
      expect(withVpn, contains('A VPN is on: if 192.168.1.50:3923 is on your home network, turn the VPN off'));
      expect(waitingForNetworkMessage(_host, vpnOn: false), isNot(contains('A VPN is on')));
      expect(waitingForNetworkMessage('https://cp.example.com', vpnOn: true), isNot(contains('A VPN is on')));
    });
  });
}
