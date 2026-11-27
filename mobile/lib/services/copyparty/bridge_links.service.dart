import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/services/copyparty/immich_bridge_status.service.dart';

/// What the bridge found behind a shared album link (`POST /api/links/inspect`).
class BridgeLinkAlbum {
  final String source;
  final String title;
  final int photos;
  final int videos;
  final List<String> days;

  /// Up to four album names, the first is the bridge's default.
  final List<String> suggestions;

  /// The person's own folder on the NAS the files are saved into first.
  final String folder;

  const BridgeLinkAlbum({
    required this.source,
    required this.title,
    required this.photos,
    required this.videos,
    required this.days,
    required this.suggestions,
    required this.folder,
  });

  static BridgeLinkAlbum fromJson(Map<dynamic, dynamic> j) => BridgeLinkAlbum(
    source: _str(j['source']),
    title: _str(j['title']),
    photos: _int(j['photos']),
    videos: _int(j['videos']),
    days: _strings(j['days']),
    suggestions: _strings(j['suggestions']),
    folder: _str(j['folder']),
  );
}

/// One import the bridge runs for the person (`GET /api/links` → jobs).
class BridgeLinkJob {
  final String id;
  final String name;
  final String source;

  /// `running`, `done`, `failed` or `stopped` (the bridge restarted).
  final String state;
  final int total;
  final int done;
  final int skipped;
  final int failed;
  final int bytes;
  final String? error;

  /// Files of this import still on the NAS (deleted once Immich has them and corrections are done).
  final int keptOnNas;

  const BridgeLinkJob({
    required this.id,
    required this.name,
    required this.source,
    required this.state,
    required this.total,
    required this.done,
    required this.skipped,
    required this.failed,
    required this.bytes,
    this.error,
    this.keptOnNas = 0,
  });

  bool get running => state == 'running';

  static BridgeLinkJob fromJson(Map<dynamic, dynamic> j) => BridgeLinkJob(
    id: _str(j['id']),
    name: _str(j['name']),
    source: _str(j['source']),
    state: _str(j['state']),
    total: _int(j['total']),
    done: _int(j['done']),
    skipped: _int(j['skipped']),
    failed: _int(j['failed']),
    bytes: _int(j['bytes']),
    error: j['error'] is String && (j['error'] as String).isNotEmpty ? j['error'] as String : null,
    keptOnNas: _int(j['kept_on_nas']),
  );
}

/// A failure, already in words for the person.
class BridgeLinkException implements Exception {
  final String message;
  const BridgeLinkException(this.message);

  @override
  String toString() => message;
}

/// A failure before the bridge answered, in words, with the technical detail for the log.
String describeTransportError(Object e) {
  if (e is TimeoutException) {
    return 'The bridge took too long to answer. Try again.';
  }
  if (e is HandshakeException || e is TlsException) {
    return 'The bridge\'s https certificate was not accepted by this phone. ($e)';
  }
  if (e is SocketException) {
    return 'The bridge could not be reached. Check you are on your home network or VPN. ($e)';
  }
  if (e is http.ClientException && e.message.toLowerCase().contains('closed')) {
    return 'The app closed its connection to the bridge too early (an app problem, not your network). '
        'Leave this page and open it again. ($e)';
  }
  return 'The app could not talk to the bridge. ($e)';
}

String _str(Object? v) => v is String ? v : '';
int _int(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);
List<String> _strings(Object? v) => v is List
    ? [
        for (final e in v)
          if (e is String && e.isNotEmpty) e,
      ]
    : const [];

/// Asks the optional import bridge to add photos from a shared album link (Google Photos or a Google
/// Drive folder). All the work happens on the bridge: it downloads into the person's own NAS folder,
/// imports into Immich and deletes the NAS copy once Immich has it. The phone only sends the link and
/// reads the progress.
///
/// The person is identified by their Immich login (`X-Immich-Token`), which is sent only to an https
/// bridge, exactly like `/status/me`. The bridge always acts for that person.
class BridgeLinksService {
  static const _lookTimeout = Duration(seconds: 90);
  static const _listTimeout = Duration(seconds: 10);

  final http.Client _client;

  BridgeLinksService({http.Client? client}) : _client = client ?? http.Client();

  void dispose() => _client.close();

  Future<BridgeLinkAlbum> inspect(String bridgeUrl, String? immichToken, String link) async {
    final body = await _call('POST', bridgeUrl, immichToken, '/api/links/inspect', {'url': link.trim()}, _lookTimeout);
    if (body is! Map) {
      throw const BridgeLinkException('The bridge gave an answer the app could not read.');
    }
    return BridgeLinkAlbum.fromJson(body);
  }

  /// Starts the import; an empty [name] lets the bridge use its first suggestion.
  Future<BridgeLinkJob> start(String bridgeUrl, String? immichToken, String link, String name) async {
    final body = await _call('POST', bridgeUrl, immichToken, '/api/links/import', {
      'url': link.trim(),
      if (name.trim().isNotEmpty) 'name': name.trim(),
    }, _lookTimeout);
    if (body is! Map) {
      throw const BridgeLinkException('The bridge gave an answer the app could not read.');
    }
    return BridgeLinkJob.fromJson(body);
  }

  Future<List<BridgeLinkJob>> jobs(String bridgeUrl, String? immichToken) async {
    final body = await _call('GET', bridgeUrl, immichToken, '/api/links', null, _listTimeout);
    final list = body is Map ? body['jobs'] : null;
    if (list is! List) {
      return const [];
    }
    return [
      for (final j in list)
        if (j is Map) BridgeLinkJob.fromJson(j),
    ];
  }

  Future<Object?> _call(
    String method,
    String bridgeUrl,
    String? immichToken,
    String path,
    Map<String, Object?>? json,
    Duration timeout,
  ) async {
    final base = ImmichBridgeStatusService.normalizeBaseUrl(bridgeUrl);
    if (base == null) {
      throw const BridgeLinkException('Set the import bridge address in Settings first.');
    }
    if (base.scheme != 'https') {
      throw const BridgeLinkException(
        'Use the bridge\'s https:// address. Your Immich login is never sent over plain http.',
      );
    }
    final token = immichToken?.trim() ?? '';
    if (token.isEmpty) {
      throw const BridgeLinkException('Sign in to Immich first.');
    }
    final basePath = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    final uri = base.replace(path: '$basePath$path');
    final headers = {'X-Immich-Token': token, if (json != null) 'Content-Type': 'application/json'};
    final http.Response response;
    try {
      response =
          await (method == 'GET'
                  ? _client.get(uri, headers: headers)
                  : _client.post(uri, headers: headers, body: jsonEncode(json)))
              .timeout(timeout);
    } catch (e) {
      throw BridgeLinkException(describeTransportError(e));
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      body = null;
    }
    final raw = body is Map && body['error'] is String ? body['error'] as String : null;
    // The bridge writes its reasons as lower-case sentences; show them as sentences.
    final error = raw == null || raw.isEmpty ? null : raw[0].toUpperCase() + raw.substring(1);
    switch (response.statusCode) {
      case 200:
      case 202:
        return body;
      case 400:
      case 409:
      case 502:
        throw BridgeLinkException(error ?? 'The bridge could not use that link.');
      case 401:
        throw const BridgeLinkException(
          'The bridge could not confirm your Immich login. Sign out and back in if this persists.',
        );
      case 404:
        throw BridgeLinkException(
          raw == 'not found' || raw == null
              ? 'This bridge cannot import shared links yet. Update it to 0.10.0 or later.'
              : 'Your Immich account is not set up on this bridge.',
        );
      case 503:
        throw const BridgeLinkException('The bridge cannot reach Immich right now. Try again later.');
      default:
        throw BridgeLinkException(error ?? 'The bridge answered with an error (HTTP ${response.statusCode}).');
    }
  }
}

/// The "Test bridge" check of shared-link imports: lists the person's link imports with a fresh connection,
/// exactly as the link page does. Never throws.
Future<({bool ok, String message})> testBridgeLinks(
  String bridgeUrl,
  String? immichToken, {
  http.Client? client,
}) async {
  final service = BridgeLinksService(client: client);
  try {
    final jobs = await service.jobs(bridgeUrl, immichToken);
    return (
      ok: true,
      message: 'Shared-link import: working (${jobs.length} recent import${jobs.length == 1 ? '' : 's'}).',
    );
  } on BridgeLinkException catch (e) {
    return (ok: false, message: 'Shared-link import: ${e.message}');
  } catch (e) {
    return (ok: false, message: 'Shared-link import: ${describeTransportError(e)}');
  } finally {
    if (client == null) {
      service.dispose();
    }
  }
}
