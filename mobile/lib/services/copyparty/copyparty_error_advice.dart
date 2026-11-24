import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';

/// What kind of failure an upload or a reachability check hit. Each kind maps to one thing the
/// user can do about it.
enum UploadFailureKind {
  /// No connection could be made (refused, no route, DNS failure, connection dropped).
  unreachable,

  /// A connection was made or attempted but nothing came back in time.
  timeout,

  /// The server refused the login or the write (HTTP 401/403).
  auth,

  /// The upload folder does not exist (HTTP 404).
  notFound,

  /// The server failed (HTTP 5xx).
  server,

  /// The TLS/certificate check failed.
  tls,

  /// copyparty refused a fresh upload over a stale partial (HTTP 422). The message already says
  /// what to do.
  stalePartial,

  /// Anything else.
  other,
}

/// A failure, turned into what the user must do and a detail line that support can match to
/// the server logs. Never contains the password.
class UploadFailureAdvice {
  final UploadFailureKind kind;

  /// The instruction shown first: what the user must do now.
  final String action;

  /// `<type> · <url> · <local time> (<UTC>) · <raw error>` for matching against server logs.
  final String detail;

  const UploadFailureAdvice({required this.kind, required this.action, required this.detail});

  /// True when the failure means the phone cannot talk to the server at all, so every other
  /// file in the batch would fail the same way.
  bool get isConnectionProblem =>
      kind == UploadFailureKind.unreachable || kind == UploadFailureKind.timeout || kind == UploadFailureKind.tls;

  /// The text stored on a failed file and shown in banners: the action, then the detail.
  String get userText => '$action\n$detail';

  static const _typeLabels = {
    UploadFailureKind.unreachable: 'not reachable',
    UploadFailureKind.timeout: 'no response (timeout)',
    UploadFailureKind.auth: 'login or permission refused',
    UploadFailureKind.notFound: 'path not found',
    UploadFailureKind.server: 'server error',
    UploadFailureKind.tls: 'certificate error',
    UploadFailureKind.stalePartial: 'stale partial upload',
    UploadFailureKind.other: 'upload error',
  };

  /// Classifies [error] from talking to copyparty at [hostUrl] / [uploadPath].
  static UploadFailureAdvice classify(
    Object error, {
    required String hostUrl,
    required String uploadPath,
    DateTime? at,
  }) {
    final host = _hostOf(hostUrl);
    final path = uploadPath.isEmpty ? '/' : uploadPath;
    final kind = kindOf(error);
    final code = statusCodeOf(error);
    final action = switch (kind) {
      UploadFailureKind.unreachable || UploadFailureKind.timeout =>
        "Can't reach $host. Check you are on home Wi-Fi, or that the VPN is connected, then tap Retry.",
      UploadFailureKind.auth =>
        'Wrong username or password, or no write access to $path. Fix it in Copyparty settings, '
            'run Test Connection, then tap Retry.',
      UploadFailureKind.notFound =>
        'The upload folder $path was not found on the server. Check the upload path in Copyparty '
            'settings, then tap Retry.',
      UploadFailureKind.server =>
        'The copyparty server had a problem${code == null ? '' : ' (HTTP $code)'}. Try again later. '
            'If it keeps happening, tell whoever runs the server.',
      UploadFailureKind.tls =>
        'Certificate problem with $host. If the server uses a self-signed certificate, turn on '
            '"Allow self-signed certificate" in Copyparty settings, then tap Retry.',
      UploadFailureKind.stalePartial => _firstLine(_messageOf(error)),
      UploadFailureKind.other => 'Upload failed. Tap Retry. If it fails again, share the diagnostic log.',
    };
    final when = at ?? DateTime.now();
    final local = when.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final localText = '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
    final utc = when.toUtc().toIso8601String().split('.').first;
    final detail =
        '${_typeLabels[kind]} · ${_withoutSecrets(hostUrl)}$path · $localText (${utc}Z) · '
        '${_firstLine(_messageOf(error))}';
    return UploadFailureAdvice(kind: kind, action: action, detail: detail);
  }

  /// The HTTP status carried by [error], if any.
  static int? statusCodeOf(Object error) {
    if (error is CopypartyUploadException) {
      if (error.statusCode != null) {
        return error.statusCode;
      }
      final m = RegExp(r'HTTP (\d{3})').firstMatch(error.message);
      return m == null ? null : int.parse(m.group(1)!);
    }
    return null;
  }

  static UploadFailureKind kindOf(Object error) {
    if (error is CopypartyUploadException) {
      if (error.stalled) {
        return UploadFailureKind.timeout;
      }
      final code = statusCodeOf(error);
      if (code == 401 || code == 403) {
        return UploadFailureKind.auth;
      }
      if (code == 404) {
        return UploadFailureKind.notFound;
      }
      if (code == 422 || error.message.contains('stale/incomplete upload')) {
        return UploadFailureKind.stalePartial;
      }
      if (code != null && code >= 500) {
        return UploadFailureKind.server;
      }
      return UploadFailureKind.other;
    }
    if (error is TimeoutException) {
      return UploadFailureKind.timeout;
    }
    if (error is HandshakeException || error is TlsException) {
      return UploadFailureKind.tls;
    }
    if (error is SocketException) {
      return UploadFailureKind.unreachable;
    }
    if (error is http.ClientException) {
      final m = error.message.toLowerCase();
      if (m.contains('certificate') || m.contains('handshake')) {
        return UploadFailureKind.tls;
      }
      return UploadFailureKind.unreachable;
    }
    return UploadFailureKind.other;
  }

  static String _messageOf(Object error) => error is CopypartyUploadException ? error.message : error.toString();

  static String _firstLine(String s) {
    final i = s.indexOf('\n');
    return (i < 0 ? s : s.substring(0, i)).trim();
  }

  static String _hostOf(String hostUrl) {
    final uri = Uri.tryParse(hostUrl.contains('://') ? hostUrl : 'https://$hostUrl');
    if (uri == null || uri.host.isEmpty) {
      return hostUrl;
    }
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  /// The host URL with any query (where a password could sit) and trailing slashes removed.
  static String _withoutSecrets(String hostUrl) {
    final uri = Uri.tryParse(hostUrl);
    final base = uri == null ? hostUrl : uri.replace(query: '', userInfo: '').toString();
    return base.replaceAll(RegExp(r'\?$'), '').replaceAll(RegExp(r'/+$'), '');
  }
}
