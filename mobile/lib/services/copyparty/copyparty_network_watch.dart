import 'dart:async';

import 'package:immich_mobile/services/copyparty/copyparty_error_advice.dart';

/// How a wait for the network ended.
enum NetworkWaitOutcome {
  /// The server answered again: resume the upload.
  recovered,

  /// The user paused or stopped while waiting.
  cancelled,

  /// Still unreachable after [CopypartyNetworkWaiter.giveUpAfter]: needs the user.
  gaveUp,

  /// The server answered but refused (for example the login): needs the user.
  blocked,
}

class NetworkWaitResult {
  final NetworkWaitOutcome outcome;

  /// The last problem seen (for gaveUp / blocked).
  final UploadFailureAdvice? advice;

  const NetworkWaitResult(this.outcome, [this.advice]);
}

/// Waits for copyparty to become reachable again after a connection loss, with back-off
/// (5 s, 10 s, 30 s, then every 60 s) and an early re-check whenever the phone's network changes.
/// Pure logic: the probe, network-change stream, clock and sleep are injected so it can be tested.
class CopypartyNetworkWaiter {
  static const backoff = [Duration(seconds: 5), Duration(seconds: 10), Duration(seconds: 30)];
  static const steady = Duration(seconds: 60);
  static const giveUpAfter = Duration(minutes: 30);

  final Future<UploadFailureAdvice?> Function() probe;
  final Stream<void>? networkChanges;
  final DateTime Function() now;
  final Future<void> Function(Duration) sleep;

  CopypartyNetworkWaiter({
    required this.probe,
    this.networkChanges,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
  }) : now = now ?? DateTime.now,
       sleep = sleep ?? Future<void>.delayed;

  static Duration delayFor(int attempt) => attempt < backoff.length ? backoff[attempt] : steady;

  /// [onWaiting] is told when the next check happens, so the UI can show it.
  Future<NetworkWaitResult> wait({
    required Future<void> cancelled,
    UploadFailureAdvice? lastProblem,
    void Function(DateTime nextCheckAt, int attempt)? onWaiting,
  }) async {
    var cancelledNow = false;
    unawaited(cancelled.then((_) => cancelledNow = true));
    Completer<void>? wake;
    final sub = networkChanges?.listen((_) {
      final w = wake;
      if (w != null && !w.isCompleted) {
        w.complete();
      }
    });
    final since = now();
    var last = lastProblem;
    try {
      for (var attempt = 0; ; attempt++) {
        if (cancelledNow) {
          return const NetworkWaitResult(NetworkWaitOutcome.cancelled);
        }
        final delay = delayFor(attempt);
        onWaiting?.call(now().add(delay), attempt);
        wake = Completer<void>();
        await Future.any<void>([sleep(delay), wake.future, cancelled]);
        if (cancelledNow) {
          return const NetworkWaitResult(NetworkWaitOutcome.cancelled);
        }
        final problem = await probe();
        if (problem == null) {
          return const NetworkWaitResult(NetworkWaitOutcome.recovered);
        }
        last = problem;
        if (!problem.isConnectionProblem) {
          return NetworkWaitResult(NetworkWaitOutcome.blocked, problem);
        }
        if (now().difference(since) >= giveUpAfter) {
          return NetworkWaitResult(NetworkWaitOutcome.gaveUp, last);
        }
      }
    } finally {
      await sub?.cancel();
    }
  }
}

/// Decides whether an upload in flight has stalled and should be aborted (to wait for the network
/// and resume), from how long no bytes have moved and what a quick reachability probe said.
/// A slow but working link (probe answers) is never aborted.
class CopypartyStallWatch {
  static const checkEvery = Duration(seconds: 15);
  static const noProgressLimit = Duration(seconds: 45);

  static bool shouldAbort({required Duration sinceProgress, required UploadFailureAdvice? probe}) {
    if (probe == null || !probe.isConnectionProblem) {
      return false;
    }
    if (probe.kind == UploadFailureKind.unreachable) {
      return true; // the connection itself is gone
    }
    return sinceProgress >= noProgressLimit; // probe timed out and nothing has moved
  }
}

/// True when [hostUrl] points at a private LAN address (or a .lan/.local/.home name), so a VPN on
/// the phone can stop it being reachable.
bool isLanHost(String hostUrl) {
  final uri = Uri.tryParse(hostUrl.contains('://') ? hostUrl : 'https://$hostUrl');
  final host = uri?.host.toLowerCase() ?? '';
  if (host.endsWith('.lan') || host.endsWith('.local') || host.endsWith('.home') || host == 'localhost') {
    return true;
  }
  final parts = host.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null || p < 0 || p > 255)) {
    return false;
  }
  final a = parts[0]!;
  final b = parts[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

/// The banner text while waiting: what is happening, what the user can do, and a VPN hint when a
/// VPN is on and the server is on the home network.
String waitingForNetworkMessage(String hostUrl, {required bool vpnOn}) {
  final uri = Uri.tryParse(hostUrl.contains('://') ? hostUrl : 'https://$hostUrl');
  final host = uri == null || uri.host.isEmpty ? hostUrl : (uri.hasPort ? '${uri.host}:${uri.port}' : uri.host);
  final vpnHint = vpnOn && isLanHost(hostUrl)
      ? ' A VPN is on: if $host is on your home network, turn the VPN off or allow local network access.'
      : '';
  return 'Lost connection to $host. Waiting to reconnect; the upload resumes by itself. '
      'Check you are on home Wi-Fi or the VPN is connected.$vpnHint';
}
