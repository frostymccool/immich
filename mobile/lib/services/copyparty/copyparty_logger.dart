import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Verbose diagnostic logger for the copyparty up2k protocol.
///
/// Captures every step of the upload (config, hashing, handshake request /
/// response, each chunk upload, finalization) into a plain-text log file that
/// the user can share/copy. The whole point is to stop guessing at errors:
/// the user runs an import, then shares the log so the exact wire exchange can
/// be inspected.
///
/// The log file lives at `<app documents>/copyparty_diag.log`. Writes are
/// serialised through a single future chain so concurrent chunk uploads don't
/// interleave or corrupt the file.
class CopypartyLogger {
  CopypartyLogger._();
  static final CopypartyLogger instance = CopypartyLogger._();

  static const String fileName = 'copyparty_diag.log';

  File? _file;
  Future<void> _writeChain = Future.value();
  final List<String> _memory = [];

  /// In-memory copy of the log (most recent session(s)). Useful for showing
  /// the tail in the UI without reading the file back.
  List<String> get lines => List.unmodifiable(_memory);

  Future<File> _resolveFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/$fileName');
    _file = f;
    return f;
  }

  /// Returns the absolute path of the log file (creating the dir if needed).
  Future<String> filePath() async => (await _resolveFile()).path;

  String _stamp() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.'
        '${three(now.millisecond)}';
  }

  /// Appends a single timestamped line to the log (memory + file).
  void log(String message) {
    final line = '${_stamp()}  $message';
    _memory.add(line);
    // Keep memory bounded so a huge import doesn't balloon RAM.
    if (_memory.length > 5000) {
      _memory.removeRange(0, _memory.length - 5000);
    }
    // ignore: avoid_print
    print('[copyparty] $line');
    _writeChain = _writeChain.then((_) async {
      try {
        final f = await _resolveFile();
        await f.writeAsString('$line\n', mode: FileMode.append, flush: false);
      } catch (_) {
        // Never let logging failures break an upload.
      }
    });
  }

  /// Visual separator + header for a new section.
  void section(String title) {
    log('');
    log('========== $title ==========');
  }

  /// Logs an outgoing HTTP request. Headers/URL are redacted of secrets.
  void request(String method, Uri uri, Map<String, String> headers, {String? body}) {
    log('>>> $method ${_redactUri(uri)}');
    headers.forEach((k, v) {
      log('    $k: ${_redactHeader(k, v)}');
    });
    if (body != null) {
      log('    body: ${_truncate(body, 2000)}');
    }
  }

  /// Logs an HTTP response. Body is included (truncated) for diagnosis.
  /// Selected headers (Server version, any up2k status, redirect Location) are
  /// logged when provided — the `Server:` header reveals the copyparty version,
  /// which is essential for spotting client/server protocol-version mismatches.
  void response(int statusCode, {Map<String, String>? headers, String? body}) {
    log('<<< HTTP $statusCode');
    if (headers != null) {
      headers.forEach((k, v) {
        final lk = k.toLowerCase();
        if (lk == 'server' || lk.startsWith('x-up2k') || lk == 'location') {
          log('    $k: $v');
        }
      });
    }
    if (body != null && body.isNotEmpty) {
      log('    body: ${_truncate(body, 2000)}');
    }
  }

  /// Truncate + flush the file to disk and return its path.
  Future<String> flush() async {
    await _writeChain;
    return filePath();
  }

  /// Clears both the in-memory buffer and the on-disk file.
  Future<void> clear() async {
    _memory.clear();
    _writeChain = _writeChain.then((_) async {
      try {
        final f = await _resolveFile();
        if (await f.exists()) {
          await f.writeAsString('');
        }
      } catch (_) {}
    });
    await _writeChain;
  }

  // -- redaction helpers ------------------------------------------------------

  static String _redactUri(Uri uri) {
    if (!uri.queryParameters.containsKey('pw')) return uri.toString();
    final params = Map<String, String>.from(uri.queryParameters);
    params['pw'] = '***';
    return uri.replace(queryParameters: params).toString();
  }

  static String _redactHeader(String key, String value) {
    final lower = key.toLowerCase();
    if (lower.contains('password') ||
        lower.contains('authorization') ||
        lower == 'pw' ||
        lower == 'x-password') {
      return '***';
    }
    return value;
  }

  static String _truncate(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}… (${s.length} bytes total)';
  }
}
