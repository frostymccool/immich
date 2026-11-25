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

  /// Best-effort check before a batch: can originals in [folder] be deleted at all? Returns null when
  /// they can (a writable folder permission covers it, or a tiny test file can be created and removed
  /// there), otherwise the system's reason (for example "Read-only file system").
  Future<String?> deleteBlockedReason(String folder) async {
    if (_android) {
      try {
        if (await _treeCanDelete(folder)) {
          return null;
        }
      } catch (_) {}
    }
    final probe = File('$folder/.immich-delete-check-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await probe.writeAsString('');
      await probe.delete();
      return null;
    } catch (e) {
      try {
        if (probe.existsSync()) {
          probe.deleteSync();
        }
      } catch (_) {}
      return e is FileSystemException ? (e.osError?.message ?? e.message) : '$e';
    }
  }
}

/// Why originals could not be deleted, in plain words, and what to do about it.
class DeleteFailureExplanation {
  /// One short sentence: the cause.
  final String cause;

  /// What the user should do.
  final String action;

  /// The system's own text, kept for the log and support.
  final String detail;

  const DeleteFailureExplanation(this.cause, this.action, this.detail);

  /// Turns the system reason (errno text from the plain delete and/or the folder-permission delete)
  /// into a cause the user recognises.
  factory DeleteFailureExplanation.of(String reason) {
    final r = reason.toLowerCase();
    if (r.contains('read-only file system') || r.contains('erofs') || r.contains('errno = 30')) {
      return DeleteFailureExplanation(
        'The memory card is read-only (write-protected), so nothing on it can be deleted.',
        'Check the lock switch on the card, its adapter or the card reader and slide it to unlocked. '
            'If there is no switch, the card may have file-system errors: repair it on a computer '
            '(Disk Utility → First Aid on a Mac, chkdsk on Windows). Do not format it until every file is '
            'uploaded. Then use "Free up space" to delete the originals.',
        reason,
      );
    }
    if (r.contains('no folder permission')) {
      return DeleteFailureExplanation(
        'Android has not given the app permission to delete on this card.',
        'Go to Import from Memory Card, pick the card folder again and allow access when Android asks, '
            'then use "Free up space".',
        reason,
      );
    }
    if (r.contains('permission denied') ||
        r.contains('eacces') ||
        r.contains('errno = 13') ||
        r.contains('operation not permitted')) {
      return DeleteFailureExplanation(
        'Android refused the app permission to delete files on this card.',
        'Go to Import from Memory Card, pick the card folder again and allow access when Android asks, '
            'then use "Free up space". If it still fails, the card may be locked or read-only: check its '
            'lock switch.',
        reason,
      );
    }
    if (r.contains('no such file') || r.contains('enoent')) {
      return DeleteFailureExplanation(
        'The original is no longer on the card (the card may have been removed or changed).',
        'Re-insert the card and try again, or remove the entry from Pending Cleanup if the file is gone.',
        reason,
      );
    }
    return DeleteFailureExplanation(
      'The app could not delete the original from the card.',
      'Try again with "Free up space". If it keeps failing, use Save log in Copyparty settings and send the log.',
      reason,
    );
  }
}

/// What the user sees once when originals cannot be deleted from this card.
String originalsKeptNotice(String reason) {
  final x = DeleteFailureExplanation.of(reason);
  return '${x.cause} Every original is kept; uploads are not affected.\n${x.action}\n(System message: ${x.detail})';
}
