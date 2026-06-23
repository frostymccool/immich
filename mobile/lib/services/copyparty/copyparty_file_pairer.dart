import 'dart:io';

import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';

/// Pairs files in a directory into upload sets based on stem matching.
///
/// Trigger files (e.g. .lrv, .insv) initiate pairing. Other files with the
/// same stem are grouped into the same set.
class CopypartyFilePairer {
  final List<String> triggerExtensions;

  const CopypartyFilePairer({
    this.triggerExtensions = const ['lrv', 'insv', 'insp'],
  });

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Scans a directory (recursively) and returns paired upload sets.
  ///
  /// [onFileFound] is called with the running total each time a file is
  /// discovered, so callers can show live progress.
  Future<List<UploadSet>> scanDirectory(
    String directoryPath, {
    void Function(int count)? onFileFound,
  }) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) {
      return [];
    }

    final allFiles = await _listFiles(dir, onFileFound: onFileFound);
    return _pairFiles(allFiles);
  }

  /// Pairs a flat list of [FileInfo] objects into upload sets.
  ///
  /// Exposed for unit testing without touching the filesystem.
  List<UploadSet> pairFiles(List<FileInfo> files) => _pairFiles(files);

  // ---------------------------------------------------------------------------
  // Stem normalisation
  // ---------------------------------------------------------------------------

  // Camera vendors that use different prefixes for companion files of the same
  // clip (e.g. LRV_*.lrv and VID_*.mp4 from DJI/GoPro).  Stripping these lets
  // the pairer recognise them as belonging to the same upload set.
  static const _stripPrefixes = ['LRV_', 'VID_', 'LIV_', 'PHO_', 'THM_'];

  /// Strips the file extension, strips known camera prefixes, then lowercases.
  String normalise(String filename) {
    var stem = filename;

    final dotIdx = stem.lastIndexOf('.');
    if (dotIdx > 0) {
      stem = stem.substring(0, dotIdx);
    }

    final upper = stem.toUpperCase();
    for (final prefix in _stripPrefixes) {
      if (upper.startsWith(prefix)) {
        stem = stem.substring(prefix.length);
        break;
      }
    }

    return stem.toLowerCase();
  }

  /// Returns the extension of a filename (without the dot), lowercased.
  static String _ext(String filename) {
    final dotIdx = filename.lastIndexOf('.');
    if (dotIdx < 0 || dotIdx == filename.length - 1) {
      return '';
    }
    return filename.substring(dotIdx + 1).toLowerCase();
  }

  // ---------------------------------------------------------------------------
  // Internal pairing logic
  // ---------------------------------------------------------------------------

  List<UploadSet> _pairFiles(List<FileInfo> files) {
    // Group files by directory
    final byDir = <String, List<FileInfo>>{};
    for (final f in files) {
      final dir = f.path.substring(0, f.path.lastIndexOf('/'));
      byDir.putIfAbsent(dir, () => []).add(f);
    }

    final sets = <UploadSet>[];

    for (final entry in byDir.entries) {
      sets.addAll(_pairFilesInDirectory(entry.value, dirPath: entry.key));
    }

    return sets;
  }

  List<UploadSet> _pairFilesInDirectory(List<FileInfo> files, {String? dirPath}) {
    // Build stem → [files] map
    final stemMap = <String, List<FileInfo>>{};
    for (final f in files) {
      final stem = normalise(f.name);
      stemMap.putIfAbsent(stem, () => []).add(f);
    }

    // Find stems that contain at least one trigger file
    final triggerStems = <String>{};
    for (final entry in stemMap.entries) {
      for (final f in entry.value) {
        if (triggerExtensions.contains(_ext(f.name))) {
          triggerStems.add(entry.key);
          break;
        }
      }
    }

    final sets = <UploadSet>[];
    final unpairedFiles = List<FileInfo>.from(files);

    for (final stem in triggerStems) {
      final group = stemMap[stem]!;
      unpairedFiles.removeWhere((f) => group.contains(f));

      final uploadFiles = group.map((f) {
        final ext = _ext(f.name);
        return UploadFile(
          localPath: f.path,
          filename: f.name,
          sizeBytes: f.sizeBytes,
          lastModifiedMs: f.lastModifiedMs,
          isTriggerFile: triggerExtensions.contains(ext),
          isNativeImmichFile: _isNativeImmichFile(ext),
        );
      }).toList();

      // Sort: trigger files first, then alphabetically
      uploadFiles.sort((a, b) {
        if (a.isTriggerFile != b.isTriggerFile) {
          return a.isTriggerFile ? -1 : 1;
        }
        return a.filename.compareTo(b.filename);
      });

      sets.add(UploadSet(files: uploadFiles, directoryPath: dirPath));
    }

    return sets;
  }

  // ---------------------------------------------------------------------------
  // Filesystem scanning
  // ---------------------------------------------------------------------------

  Future<List<FileInfo>> _listFiles(
    Directory dir, {
    void Function(int count)? onFileFound,
  }) async {
    final result = <FileInfo>[];
    await for (final entity in dir.list(recursive: true, followLinks: true)) {
      if (entity is File) {
        try {
          final stat = await entity.stat();
          result.add(
            FileInfo(
              path: entity.path,
              name: entity.path.split('/').last,
              sizeBytes: stat.size,
              lastModifiedMs: stat.modified.millisecondsSinceEpoch,
            ),
          );
          onFileFound?.call(result.length);
        } catch (_) {
          // Skip files we can't stat
        }
      }
    }
    return result;
  }

  // Files Immich handles natively (no need to route through copyparty)
  static const _nativeImmichExtensions = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif',
    'mp4', 'mov', 'avi', 'mkv', 'webm',
    'raw', 'arw', 'cr2', 'cr3', 'nef', 'orf', 'rw2',
  };

  static bool _isNativeImmichFile(String ext) =>
      _nativeImmichExtensions.contains(ext);
}

/// Lightweight file descriptor used during scanning.
class FileInfo {
  final String path;
  final String name;
  final int sizeBytes;
  final int lastModifiedMs;

  const FileInfo({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.lastModifiedMs,
  });
}
