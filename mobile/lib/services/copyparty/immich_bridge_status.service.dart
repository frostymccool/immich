import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

enum BridgeHealth { disabled, invalidUrl, unreachable, running }

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
  final List<BridgeRecentItem> recent;
  final DateTime checkedAt;

  const BridgeStatus({
    required this.health,
    required this.checkedAt,
    this.version,
    this.counts = const {},
    this.queue = 0,
    this.recent = const [],
  });

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

/// Reads the optional copyparty-immich-bridge's /healthz and /status.
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

  Future<BridgeStatus> fetch(String rawUrl) async {
    final checkedAt = _now();
    if (rawUrl.trim().isEmpty) {
      return BridgeStatus(health: BridgeHealth.disabled, checkedAt: checkedAt);
    }
    final base = normalizeBaseUrl(rawUrl);
    if (base == null) {
      return BridgeStatus(health: BridgeHealth.invalidUrl, checkedAt: checkedAt);
    }

    try {
      final healthBody = await _getJson(base, '/healthz');
      if (healthBody is! Map || healthBody['ok'] != true) {
        return BridgeStatus(health: BridgeHealth.unreachable, checkedAt: checkedAt);
      }
      final version = healthBody['version'] is String ? healthBody['version'] as String : null;

      // /status adds detail; the bridge is still "running" if only this part fails.
      try {
        final statusBody = await _getJson(base, '/status');
        if (statusBody is Map) {
          return BridgeStatus(
            health: BridgeHealth.running,
            checkedAt: checkedAt,
            version: version,
            counts: _parseCounts(statusBody['counts']),
            queue: statusBody['queue'] is int ? statusBody['queue'] as int : 0,
            recent: _parseRecent(statusBody['recent']),
          );
        }
      } catch (_) {
        // fall through to the health-only result
      }
      return BridgeStatus(health: BridgeHealth.running, checkedAt: checkedAt, version: version);
    } catch (_) {
      return BridgeStatus(health: BridgeHealth.unreachable, checkedAt: checkedAt);
    }
  }

  Future<Object?> _getJson(Uri base, String path) async {
    final basePath = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    final response = await _client.get(base.replace(path: '$basePath$path')).timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException('HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

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
