import 'dart:io';

import 'package:flutter/services.dart';

/// The outcome of deleting an original from the memory card.
class SourceDeleteResult {
  final bool ok;

  /// Why it failed (both attempts), for the file's note and the log.
  final String? reason;

  const SourceDeleteResult.deleted() : ok = true, reason = null;
  const SourceDeleteResult.failed(this.reason) : ok = false;
}

/// Deletes originals from a memory card or USB drive.
///
/// First a plain file delete. On Android 11+ that is often refused for removable storage even with
/// "All files access", so it then deletes through the folder permission Android granted when the
/// user picked the folder (a persisted tree URI with write access).
class CopypartySourceDeleter {
  static const _channel = MethodChannel('immich/saf_picker');

  final Future<Map<String, Object?>?> Function(String path) _treeDelete;
  final Future<bool> Function(String path) _treeCanDelete;
  final bool _android;

  CopypartySourceDeleter({
    Future<Map<String, Object?>?> Function(String path)? treeDelete,
    Future<bool> Function(String path)? treeCanDelete,
    bool? android,
  }) : _treeDelete = treeDelete ?? _channelDelete,
       _treeCanDelete = treeCanDelete ?? _channelCanDelete,
       _android = android ?? Platform.isAndroid;

  static Future<Map<String, Object?>?> _channelDelete(String path) =>
      _channel.invokeMapMethod<String, Object?>('deleteFile', {'path': path});

  static Future<bool> _channelCanDelete(String path) async =>
      await _channel.invokeMethod<bool>('canDelete', {'path': path}) ?? false;

  Future<SourceDeleteResult> delete(String path) async {
    final file = File(path);
    String plainError;
    try {
      await file.delete();
      return const SourceDeleteResult.deleted();
    } catch (e) {
      plainError = e is FileSystemException ? (e.osError?.message ?? e.message) : '$e';
    }
    if (!file.existsSync()) {
      return const SourceDeleteResult.deleted();
    }
    if (!_android) {
      return SourceDeleteResult.failed(plainError);
    }
    String treeError;
    try {
      final r = await _treeDelete(path);
      if (r?['ok'] == true || !file.existsSync()) {
        return const SourceDeleteResult.deleted();
      }
      treeError = '${r?['error'] ?? 'no answer'}';
    } catch (e) {
      treeError = '$e';
    }
    return SourceDeleteResult.failed('$plainError; with the folder permission: $treeError');
  }

  /// Best-effort check before a batch: can originals in [folder] be deleted at all? True when a
  /// writable folder permission covers it, or a tiny test file can be created and removed there.
  Future<bool> canDeleteIn(String folder) async {
    if (_android) {
      try {
        if (await _treeCanDelete(folder)) {
          return true;
        }
      } catch (_) {}
    }
    final probe = File('$folder/.immich-delete-check-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await probe.writeAsString('');
      await probe.delete();
      return true;
    } catch (_) {
      try {
        if (probe.existsSync()) {
          probe.deleteSync();
        }
      } catch (_) {}
      return false;
    }
  }
}

/// What the user sees once when originals cannot be deleted from this card.
String originalsKeptNotice(String reason) =>
    'Auto-delete is on, but the app cannot delete files on this card, so every original is kept '
    '(uploads are not affected). To fix it: go back, pick the card folder again and allow access when '
    'Android asks, then use "Free up space" in Copyparty settings. Reason: $reason';
