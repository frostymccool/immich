import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/copyparty/copyparty.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

/// The full multi-step "Import from Memory Card" flow.
///
/// Steps: directory picker → scan → options → progress → completion
class CopypartyImportPage extends ConsumerWidget {
  const CopypartyImportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(importSessionProvider);

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) ref.read(importSessionProvider.notifier).reset();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Import from Memory Card'),
          centerTitle: false,
        ),
        body: switch (session.step) {
          ImportSessionStep.idle => const _DirectoryPickerStep(),
          ImportSessionStep.scanning => _ScanningStep(session),
          ImportSessionStep.options => _OptionsStep(session),
          ImportSessionStep.uploading => _UploadProgressStep(session),
          ImportSessionStep.complete => _CompletionStep(session),
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 1: Directory browser
// ---------------------------------------------------------------------------

class _DirectoryPickerStep extends ConsumerStatefulWidget {
  const _DirectoryPickerStep();

  @override
  ConsumerState<_DirectoryPickerStep> createState() => _DirectoryPickerStepState();
}

class _DirectoryPickerStepState extends ConsumerState<_DirectoryPickerStep> {
  final List<String> _pathStack = []; // empty → roots view
  List<_DirEntry> _entries = [];
  bool _loading = true;
  bool _hasFullStorageAccess = true;
  String? _error;

  String? get _currentPath => _pathStack.isEmpty ? null : _pathStack.last;

  @override
  void initState() {
    super.initState();
    _checkPermissionAndLoad();
  }

  Future<void> _checkPermissionAndLoad() async {
    final status = await Permission.manageExternalStorage.status;
    if (mounted) setState(() => _hasFullStorageAccess = status.isGranted);
    _load(null);
  }

  Future<void> _requestFullStorageAccess() async {
    await Permission.manageExternalStorage.request();
    final status = await Permission.manageExternalStorage.status;
    if (mounted) {
      setState(() => _hasFullStorageAccess = status.isGranted);
      _load(null);
    }
  }

  Future<void> _load(String? path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = path == null ? await _loadRoots() : await _loadDirectory(path);
      if (mounted) setState(() { _entries = entries; _loading = false; });
    } catch (e) {
      final isPermissionError = '$e'.contains('Permission denied') ||
          '$e'.contains('EACCES') || '$e'.contains('Operation not permitted');
      if (isPermissionError && path != null && !path.contains('/emulated/')) {
        final status = await Permission.manageExternalStorage.request();
        if (status.isGranted) {
          setState(() => _hasFullStorageAccess = true);
          _load(path);
          return;
        }
        if (mounted) {
          setState(() {
            _error = 'Storage access denied.\n\n'
                'Tap "Grant Access" at the top to enable full storage access.';
            _loading = false;
          });
        }
      } else {
        if (mounted) setState(() { _error = '$e'; _loading = false; });
      }
    }
  }

  Future<List<_DirEntry>> _loadRoots() async {
    final seenPaths = <String>{};
    final roots = <_DirEntry>[];

    // 1. Internal storage — always first
    const internal = '/storage/emulated/0';
    if (await Directory(internal).exists()) {
      roots.add(const _DirEntry(path: internal, label: 'Internal Storage'));
      seenPaths.add(internal);
    }

    // 2. getExternalStorageDirectories() — the proper Android API; returns
    //    app-specific paths for EVERY mounted volume (SD card, USB OTG, hub).
    //    Strip the app suffix to get the volume root.
    try {
      final externalDirs = await getExternalStorageDirectories();
      if (externalDirs != null) {
        for (final dir in externalDirs) {
          final rootPath = _extractStorageRoot(dir.path);
          if (rootPath != null && rootPath != internal && seenPaths.add(rootPath)) {
            final name = rootPath.split('/').last;
            roots.add(_DirEntry(path: rootPath, label: 'External — $name'));
          }
        }
      }
    } catch (_) {}

    // 3. /proc/mounts — catches volumes not in externalDirs (e.g. SD card on some devices)
    try {
      final lines = await File('/proc/mounts').readAsLines();
      for (final line in lines) {
        final parts = line.split(' ');
        if (parts.length < 2) continue;
        final mp = parts[1];
        final match = RegExp(r'^/storage/([^/]+)$').firstMatch(mp);
        if (match != null) {
          final name = match.group(1)!;
          if (name != 'emulated' && name != 'self' && seenPaths.add(mp)) {
            roots.add(_DirEntry(path: mp, label: 'External — $name'));
          }
        }
      }
    } catch (_) {}

    // 4. /storage/ directory scan and /mnt/media_rw/ as final fallbacks
    for (final base in ['/storage', '/mnt/media_rw']) {
      try {
        await for (final entity in Directory(base).list(followLinks: false)) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (name != 'emulated' && name != 'self' &&
                !seenPaths.any((p) => p.endsWith('/$name'))) {
              seenPaths.add(entity.path);
              roots.add(_DirEntry(path: entity.path, label: 'External — $name'));
            }
          }
        }
      } catch (_) {}
    }

    return roots;
  }

  static String? _extractStorageRoot(String appPath) {
    final parts = appPath.split('/');
    if (parts.length < 3) return null;
    // /storage/emulated/0/Android/... → /storage/emulated/0
    if (parts.length >= 4 && parts[2] == 'emulated') {
      return '/${parts[1]}/${parts[2]}/${parts[3]}';
    }
    // /storage/UUID/Android/... → /storage/UUID
    return '/${parts[1]}/${parts[2]}';
  }

  Future<List<_DirEntry>> _loadDirectory(String path) async {
    final entries = <_DirEntry>[];
    await for (final entity in Directory(path).list(followLinks: false)) {
      if (entity is Directory) {
        final name = entity.path.split('/').last;
        if (!name.startsWith('.')) {
          entries.add(_DirEntry(path: entity.path, label: name));
        }
      }
    }
    entries.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return entries;
  }

  void _enter(String path) {
    _pathStack.add(path);
    _load(path);
  }

  void _back() {
    if (_pathStack.isEmpty) return;
    _pathStack.removeLast();
    _load(_currentPath);
  }

  @override
  Widget build(BuildContext context) {
    final canGoBack = _pathStack.isNotEmpty;
    final canScan = _currentPath != null;

    return Column(
      children: [
        // Full storage access banner
        if (!_hasFullStorageAccess)
          MaterialBanner(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            content: const Text(
              'Grant "All files access" to detect USB drives and SD cards.',
            ),
            leading: const Icon(Icons.usb_rounded),
            actions: [
              TextButton(
                onPressed: _requestFullStorageAccess,
                child: const Text('Grant Access'),
              ),
            ],
          ),
        // Breadcrumb bar
        Container(
          color: context.colorScheme.surfaceContainer,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              if (canGoBack)
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: _back,
                  tooltip: 'Go up',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                )
              else
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.storage_rounded, size: 20),
                ),
              Expanded(
                child: Text(
                  _currentPath ?? 'Select storage',
                  style: context.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        // Directory list
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator.adaptive())
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.lock_outline, size: 48,
                                color: context.colorScheme.error),
                            const SizedBox(height: 12),
                            Text(
                              'Cannot read directory',
                              style: context.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: context.textTheme.bodySmall,
                            ),
                            if (canGoBack) ...[
                              const SizedBox(height: 16),
                              OutlinedButton(
                                onPressed: _back,
                                child: const Text('Go back'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : _entries.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.folder_open_outlined, size: 48,
                                  color: context.colorScheme.onSurface.withValues(alpha: 0.4)),
                              const SizedBox(height: 12),
                              Text(
                                _currentPath == null
                                    ? 'No storage volumes found'
                                    : 'No subfolders here',
                                style: context.textTheme.bodyMedium,
                              ),
                              if (_currentPath != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Tap "Scan This Folder" to scan files here.',
                                  style: context.textTheme.bodySmall,
                                ),
                              ],
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: _entries.length,
                          itemBuilder: (ctx, i) {
                            final e = _entries[i];
                            return ListTile(
                              leading: const Icon(Icons.folder_rounded),
                              title: Text(e.label),
                              subtitle: _currentPath == null
                                  ? Text(e.path, style: ctx.textTheme.bodySmall)
                                  : null,
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () => _enter(e.path),
                            );
                          },
                        ),
        ),
        // Scan button
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: canScan
                    ? () => ref.read(importSessionProvider.notifier).scan(_currentPath!)
                    : null,
                icon: const Icon(Icons.search_rounded),
                label: const Text('Scan This Folder'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DirEntry {
  final String path;
  final String label;
  const _DirEntry({required this.path, required this.label});
}

// ---------------------------------------------------------------------------
// Step 2: Scanning
// ---------------------------------------------------------------------------

class _ScanningStep extends StatelessWidget {
  final ImportSessionState session;
  const _ScanningStep(this.session);

  @override
  Widget build(BuildContext context) {
    final count = session.scannedFiles;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator.adaptive(),
          const SizedBox(height: 24),
          const Text('Scanning directory for files…'),
          if (count > 0) ...[
            const SizedBox(height: 8),
            Text(
              '$count file${count == 1 ? '' : 's'} found',
              style: context.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 3: Options / scan results
// ---------------------------------------------------------------------------

class _OptionsStep extends ConsumerWidget {
  final ImportSessionState session;

  const _OptionsStep(this.session);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sets = session.uploadSets;
    final totalFiles = sets.fold(0, (s, u) => s + u.files.length);
    final totalBytes = sets.fold(0, (s, u) => s + u.totalBytes);

    if (sets.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.folder_off_outlined,
              size: 64,
              color: context.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            const Text('No matching files found'),
            const SizedBox(height: 8),
            Text(
              'No files with the configured trigger extensions were found.\n'
              'Check your trigger extensions in Copyparty settings.',
              textAlign: TextAlign.center,
              style: context.textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: () => ref.read(importSessionProvider.notifier).reset(),
              child: const Text('Try Again'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Summary bar
        Container(
          color: context.colorScheme.surfaceContainer,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.file_copy_outlined),
              const SizedBox(width: 8),
              Text(
                '$totalFiles files in ${sets.length} upload sets '
                '(${formatHumanReadableBytes(totalBytes, 1)})',
                style: context.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
        // Upload set list
        Expanded(
          child: ListView.builder(
            itemCount: sets.length,
            itemBuilder: (ctx, i) => _UploadSetTile(set: sets[i]),
          ),
        ),
        // Upload button
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => ref.read(importSessionProvider.notifier).startUpload(),
                icon: const Icon(Icons.upload_rounded),
                label: Text('Upload $totalFiles files'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _UploadSetTile extends StatelessWidget {
  final UploadSet set;
  const _UploadSetTile({required this.set});

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Icons.folder_zip_outlined),
      title: Text(set.displayName),
      subtitle: Text(
        '${set.files.length} files · ${formatHumanReadableBytes(set.totalBytes, 1)}',
      ),
      children: set.files.map((f) => _FileTile(file: f)).toList(),
    );
  }
}

class _FileTile extends StatelessWidget {
  final UploadFile file;
  const _FileTile({required this.file});

  @override
  Widget build(BuildContext context) {
    final badges = <String>[];
    if (file.isTriggerFile) badges.add('trigger');
    if (file.isNativeImmichFile) badges.add('also in Immich');

    return ListTile(
      contentPadding: const EdgeInsets.only(left: 32, right: 16),
      leading: Icon(
        file.isTriggerFile ? Icons.star_rounded : Icons.insert_drive_file_outlined,
        color: file.isTriggerFile ? context.primaryColor : null,
        size: 20,
      ),
      title: Text(file.filename, style: context.textTheme.bodyMedium),
      subtitle: Text(
        [formatHumanReadableBytes(file.sizeBytes, 1), ...badges].join(' · '),
        style: context.textTheme.bodySmall,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 4: Upload progress
// ---------------------------------------------------------------------------

class _UploadProgressStep extends StatelessWidget {
  final ImportSessionState session;
  const _UploadProgressStep(this.session);

  @override
  Widget build(BuildContext context) {
    final allFiles = session.uploadSets.expand((s) => s.files).toList();

    return Column(
      children: [
        // Overall progress bar
        LinearProgressIndicator(
          value: session.totalFiles > 0
              ? session.completedFiles / session.totalFiles
              : null,
          minHeight: 6,
        ),
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${session.completedFiles} / ${session.totalFiles} files',
                style: context.textTheme.titleMedium,
              ),
              Text(
                formatHumanReadableBytes(
                  allFiles.fold(0, (s, f) => s + f.uploadedBytes),
                  1,
                ),
                style: context.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: allFiles.length,
            itemBuilder: (ctx, i) => _ProgressFileTile(file: allFiles[i]),
          ),
        ),
      ],
    );
  }
}

class _ProgressFileTile extends StatelessWidget {
  final UploadFile file;
  const _ProgressFileTile({required this.file});

  @override
  Widget build(BuildContext context) {
    final isDone = file.status == UploadFileStatus.receiptWritten ||
        file.status == UploadFileStatus.confirmed;
    final isFailed = file.status == UploadFileStatus.failed;

    Widget trailing;
    if (isFailed) {
      trailing = const Icon(Icons.error_rounded, color: Colors.red, size: 20);
    } else if (isDone) {
      trailing = Icon(Icons.check_circle_rounded, color: context.primaryColor, size: 20);
    } else {
      trailing = SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator.adaptive(
          strokeWidth: 2,
          value: file.sizeBytes > 0 ? file.progress : null,
        ),
      );
    }

    return ListTile(
      dense: true,
      title: Text(file.filename, style: context.textTheme.bodyMedium),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_statusLabel(file.status), style: context.textTheme.bodySmall),
          if (!isDone && !isFailed && file.sizeBytes > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: file.progress,
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          if (isFailed && file.errorMessage != null)
            Text(
              file.errorMessage!,
              style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
      trailing: trailing,
    );
  }

  String _statusLabel(UploadFileStatus status) => switch (status) {
    UploadFileStatus.pending => 'Waiting…',
    UploadFileStatus.hashing => 'Hashing…',
    UploadFileStatus.handshaking => 'Handshaking…',
    UploadFileStatus.uploading => 'Uploading…',
    UploadFileStatus.confirmed => 'Verified',
    UploadFileStatus.receiptWritten => 'Done ✓',
    UploadFileStatus.failed => 'Failed',
  };
}

// ---------------------------------------------------------------------------
// Step 5: Completion
// ---------------------------------------------------------------------------

class _CompletionStep extends ConsumerWidget {
  final ImportSessionState session;

  const _CompletionStep(this.session);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allFiles = session.uploadSets.expand((s) => s.files).toList();
    final succeeded = allFiles.where((f) => f.status == UploadFileStatus.receiptWritten).length;
    final failed = allFiles.where((f) => f.status == UploadFileStatus.failed).length;
    final safeToDelete = allFiles.where((f) => f.safeToDelete).toList();

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed == 0 ? Icons.check_circle_rounded : Icons.warning_rounded,
                color: failed == 0 ? context.primaryColor : context.colorScheme.error,
                size: 36,
              ),
              const SizedBox(width: 12),
              Text(
                failed == 0 ? 'Upload Complete' : 'Completed with errors',
                style: context.textTheme.headlineSmall,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SummaryRow('Uploaded', '$succeeded files'),
          if (failed > 0) _SummaryRow('Failed', '$failed files', isError: true),
          _SummaryRow('Safe to delete', '${safeToDelete.length} files'),
          const SizedBox(height: 24),
          if (safeToDelete.isNotEmpty) ...[
            Text(
              'The following files are verified and have receipts written. '
              'You can safely delete them from the memory card.',
              style: context.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Container(
              height: 160,
              decoration: BoxDecoration(
                border: Border.all(color: context.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                itemCount: safeToDelete.length,
                itemBuilder: (ctx, i) {
                  final f = safeToDelete[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.check_circle_outline, size: 18),
                    title: Text(f.filename, style: context.textTheme.bodySmall),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _confirmDelete(context, ref, safeToDelete),
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text('Delete ${safeToDelete.length} verified files'),
              ),
            ),
            const SizedBox(height: 8),
          ],
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                ref.read(importSessionProvider.notifier).reset();
                Navigator.of(context).pop();
              },
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, List<UploadFile> files) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Source Files'),
        content: Text(
          'Delete ${files.length} files from the memory card? '
          'All files have been uploaded and verified.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      int deleted = 0;
      for (final file in files) {
        try {
          await File(file.localPath).delete();
          deleted++;
        } catch (_) {}
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted $deleted / ${files.length} files')),
        );
      }
    }
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isError;

  const _SummaryRow(this.label, this.value, {this.isError = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: context.textTheme.bodyMedium),
          Text(
            value,
            style: context.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: isError ? context.colorScheme.error : null,
            ),
          ),
        ],
      ),
    );
  }
}
