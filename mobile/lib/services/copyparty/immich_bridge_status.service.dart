import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

enum BridgeHealth { disabled, invalidUrl, unreachable, running }

/// Whose information the bridge showed. Personal detail (counts, folders, albums, recent files) only ever
/// comes from `/status/me`, which identifies the person by their own Immich login; the open `/status`
/// is never read for it, so one person can never see another's imports.
enum BridgeAccess {
  /// Not asked yet (bridge disabled, invalid or unreachable).
  notChecked,

  /// `/status/me` answered for this person.
  signedIn,

  /// The bridge URL is plain http: the Immich login is never sent without TLS.
  needsHttps,

  /// The app has no Immich login to identify the person with.
  notSignedIn,

  /// The bridge could not confirm the Immich login (HTTP 401).
  tokenRejected,

  /// A valid Immich user that has no account on the bridge (HTTP 404 "not a bridge user").
  notBridgeUser,

  /// The bridge cannot reach Immich right now (HTTP 503): try later, the person is not signed out.
  immichUnreachable,

  /// The bridge predates `/status/me` (older than 0.8.0).
  bridgeTooOld,

  /// Any other failure of the personal status request.
  failed,
}

class BridgeRecentItem {
  final String path;
  final String status;
  final String? error;
  final int attempts;
  final DateTime? updatedAt;

  const BridgeRecentItem({required this.path, required this.status, this.error, this.attempts = 0, this.updatedAt});

  String get fileName {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }
}

class BridgeStatus {
  final BridgeHealth health;
  final String? version;
  final Map<String, int> counts;
  final int queue;
  final List<String> watchDirs;
  final List<String> priorityDirs;
  final List<BridgeRecentItem> recent;
  final DateTime checkedAt;

  /// The normalised bridge address (also serves its web page); null unless the URL parsed.
  final Uri? baseUrl;

  final BridgeAccess access;

  /// The person the bridge identified (its display name for them), when [access] is [BridgeAccess.signedIn].
  final String? signedInAs;

  const BridgeStatus({
    required this.health,
    required this.checkedAt,
    this.version,
    this.counts = const {},
    this.queue = 0,
    this.watchDirs = const [],
    this.priorityDirs = const [],
    this.recent = const [],
    this.baseUrl,
    this.access = BridgeAccess.notChecked,
    this.signedInAs,
  });

  /// One line for the "Test bridge" result and the status tile when no personal detail is shown.
  String get accessMessage => switch (access) {
    BridgeAccess.signedIn => 'Signed in as ${signedInAs ?? 'you'}',
    BridgeAccess.needsHttps =>
      'Use the bridge\'s https:// address to see your own imports. Your Immich login is never sent over plain http.',
    BridgeAccess.notSignedIn => 'Sign in to Immich to see your own imports.',
    BridgeAccess.tokenRejected =>
      'The bridge could not confirm your Immich login. Sign out and back in if this persists.',
    BridgeAccess.notBridgeUser => 'Your Immich account is not set up on this bridge.',
    BridgeAccess.immichUnreachable => 'The bridge cannot reach Immich right now. Try again later.',
    BridgeAccess.bridgeTooOld => 'This bridge is too old to show your own imports. Update it to 0.8.0 or later.',
    BridgeAccess.failed => 'Could not read your bridge status. Try again later.',
    BridgeAccess.notChecked => '',
  };

  int get imported => counts['imported'] ?? 0;
  int get duplicates => counts['duplicate'] ?? 0;
  int get failed => counts['failed'] ?? 0;
  int get skipped => counts['skipped'] ?? 0;

  /// Most recent time the bridge recorded any file outcome.
  DateTime? get lastActivity {
    DateTime? latest;
    for (final item in recent) {
      final t = item.updatedAt;
      if (t != null && (latest == null || t.isAfter(latest))) {
        latest = t;
      }
    }
    return latest;
  }
}

/// Reads the optional copyparty-immich-bridge's /healthz and, for the signed-in person only, /status/me.
///
/// Strictly best-effort and informational: every failure mode (blank URL, bad
/// URL, bridge down, slow, garbage response) maps to a [BridgeStatus] and is
/// never thrown, so nothing else in the app can ever depend on the bridge.
class ImmichBridgeStatusService {
  static const _timeout = Duration(seconds: 4);

  final http.Client _client;
  final DateTime Function() _now;

  ImmichBridgeStatusService({http.Client? client, DateTime Function()? now})
    : _client = client ?? http.Client(),
      _now = now ?? DateTime.now;

  void dispose() => _client.close();

  /// Returns null when [raw] is not a usable http(s) URL.
  static Uri? normalizeBaseUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) {
      return null;
    }
    if (!value.contains('://')) {
      value = 'http://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri;
  }

  /// [immichToken] is the app's Immich access token. It is sent only to an https bridge URL, in the
  /// `X-Immich-Token` header, and the bridge answers with that person's own status.
  Future<BridgeStatus> fetch(String rawUrl, {String? immichToken}) async {
    final checkedAt = _now();
    if (rawUrl.trim().isEmpty) {
      return BridgeStatus(health: BridgeHealth.disabled, checkedAt: checkedAt);
    }
    final base = normalizeBaseUrl(rawUrl);
    if (base == null) {
      return BridgeStatus(health: BridgeHealth.invalidUrl, checkedAt: checkedAt);
    }

    final String? version;
    try {
      final health = await _get(base, '/healthz');
      final healthBody = health.statusCode == 200 ? jsonDecode(utf8.decode(health.bodyBytes)) : null;
      if (healthBody is! Map || healthBody['ok'] != true) {
        return BridgeStatus(health: BridgeHealth.unreachable, checkedAt: checkedAt);
      }
      version = healthBody['version'] is String ? healthBody['version'] as String : null;
    } catch (_) {
      return BridgeStatus(health: BridgeHealth.unreachable, checkedAt: checkedAt);
    }

    BridgeStatus running(BridgeAccess access) => BridgeStatus(
      health: BridgeHealth.running,
      checkedAt: checkedAt,
      version: version,
      baseUrl: base,
      access: access,
    );

    if (base.scheme != 'https') {
      return running(BridgeAccess.needsHttps);
    }
    final token = immichToken?.trim() ?? '';
    if (token.isEmpty) {
      return running(BridgeAccess.notSignedIn);
    }

    try {
      final response = await _get(base, '/status/me', headers: {'X-Immich-Token': token});
      Object? body;
      try {
        body = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (_) {
        body = null;
      }
      switch (response.statusCode) {
        case 200 when body is Map:
          final me = body['me'];
          final who = me is Map && me['name'] is String && (me['name'] as String).isNotEmpty
              ? me['name'] as String
              : null;
          return BridgeStatus(
            health: BridgeHealth.running,
            checkedAt: checkedAt,
            baseUrl: base,
            version: version,
            access: BridgeAccess.signedIn,
            signedInAs: who,
            counts: _parseCounts(body['counts']),
            queue: body['queue'] is int ? body['queue'] as int : 0,
            watchDirs: _parseStrings(body['watch_dirs']),
            priorityDirs: _parseStrings(body['priority_dirs']),
            recent: _parseRecent(body['recent']),
          );
        case 401:
          return running(BridgeAccess.tokenRejected);
        case 404:
          final notUser = body is Map && body['error'] == 'not a bridge user';
          return running(notUser ? BridgeAccess.notBridgeUser : BridgeAccess.bridgeTooOld);
        case 503:
          return running(BridgeAccess.immichUnreachable);
        default:
          return running(BridgeAccess.failed);
      }
    } catch (_) {
      return running(BridgeAccess.failed);
    }
  }

  Future<http.Response> _get(Uri base, String path, {Map<String, String>? headers}) {
    final basePath = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    return _client.get(base.replace(path: '$basePath$path'), headers: headers).timeout(_timeout);
  }

  static List<String> _parseStrings(Object? raw) => raw is List
      ? [
          for (final e in raw)
            if (e is String) e,
        ]
      : const [];

  static Map<String, int> _parseCounts(Object? raw) {
    if (raw is! Map) {
      return const {};
    }
    return {
      for (final e in raw.entries)
        if (e.key is String && e.value is int) e.key as String: e.value as int,
    };
  }

  static List<BridgeRecentItem> _parseRecent(Object? raw) {
    if (raw is! List) {
      return const [];
    }
    final items = <BridgeRecentItem>[];
    for (final entry in raw) {
      if (entry is! Map || entry['path'] is! String || entry['status'] is! String) {
        continue;
      }
      final updated = entry['updated_at'];
      items.add(
        BridgeRecentItem(
          path: entry['path'] as String,
          status: entry['status'] as String,
          error: entry['error'] is String ? entry['error'] as String : null,
          attempts: entry['attempts'] is int ? entry['attempts'] as int : 0,
          updatedAt: updated is num ? DateTime.fromMillisecondsSinceEpoch((updated * 1000).round()) : null,
        ),
      );
    }
    return items;
  }
}
