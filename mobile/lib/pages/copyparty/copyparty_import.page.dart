import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
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
        if (didPop) {
          ref.read(importSessionProvider.notifier).reset();
        }
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
// Step 1: Folder picker (uses Android SAF via file_picker)
// ---------------------------------------------------------------------------

class _DirectoryPickerStep extends ConsumerStatefulWidget {
  const _DirectoryPickerStep();

  @override
  ConsumerState<_DirectoryPickerStep> createState() => _DirectoryPickerStepState();
}

class _DirectoryPickerStepState extends ConsumerState<_DirectoryPickerStep> {
  String? _selectedPath;
  bool _picking = false;

  Future<void> _browse() async {
    setState(() => _picking = true);
    try {
      final raw = await FilePicker.platform.getDirectoryPath();
      if (raw == null || !mounted) {
        return;
      }

      final resolved = _resolveSafPath(raw);

      if (resolved.isNotEmpty && resolved != '/') {
        setState(() => _selectedPath = resolved);
        return;
      }

      // file_picker returned an unusable path — scan /storage/ for removable volumes
      final candidates = await _findRemovableStoragePaths();
      if (!mounted) {
        return;
      }

      if (candidates.length == 1) {
        setState(() => _selectedPath = candidates.first);
      } else if (candidates.isNotEmpty) {
        final chosen = await _showStorageChooserDialog(candidates);
        if (chosen != null && mounted) {
          setState(() => _selectedPath = chosen);
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not resolve USB path '
              '(picker returned: "${_truncate(raw, 60)}"). '
              'Please enter the path manually.',
            ),
            duration: const Duration(seconds: 10),
          ),
        );
        await _showManualEntry();
      }
    } finally {
      if (mounted) {
        setState(() => _picking = false);
      }
    }
  }

  Future<void> _scanWithPermissionCheck(String path) async {
    if (Platform.isAndroid) {
      final granted = await Permission.manageExternalStorage.isGranted;
      if (!granted) {
        if (!mounted) {
          return;
        }
        final goToSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('All Files Access Required'),
            content: const Text(
              'Scanning external storage (USB drives, SD cards) requires '
              '"All files access".\n\n'
              'Open Settings → Apps → Immich → Permissions → Files and media → '
              'Allow management of all files.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
        if (goToSettings == true) {
          await openAppSettings();
        }
        return;
      }
    }
    ref.read(importSessionProvider.notifier).scan(path);
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  static Future<List<String>> _findRemovableStoragePaths() async {
    final found = <String>[];
    try {
      final storageDir = Directory('/storage');
      if (!await storageDir.exists()) {
        return found;
      }
      await for (final entity in storageDir.list()) {
        if (entity is! Directory) {
          continue;
        }
        final name = entity.path.split('/').last;
        if (name == 'emulated' || name == 'self') {
          continue;
        }
        // Removable storage volumes use a XXXX-XXXX hex UUID format
        if (RegExp(r'^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$').hasMatch(name)) {
          found.add(entity.path);
        }
      }
    } catch (_) {}
    return found;
  }

  Future<String?> _showStorageChooserDialog(List<String> paths) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Select USB Drive'),
        children: paths
            .map(
              (p) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, p),
                child: Text(
                  p.split('/').last,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  /// Converts an Android SAF content URI to a real filesystem path.
  ///
  /// file_picker on Android 11+ returns a content URI from ACTION_OPEN_DOCUMENT_TREE
  /// (e.g. content://com.android.externalstorage.documents/tree/XXXX-XXXX%3ADCIM).
  /// dart:io cannot open content URIs directly, so we extract the volume ID and
  /// relative path and reconstruct the real /storage/<volume>/<path> location.
  static String _resolveSafPath(String raw) {
    if (!raw.startsWith('content://')) {
      return raw;
    }
    try {
      final uri = Uri.parse(raw);
      // pathSegments are percent-decoded by Uri.parse:
      // ['tree', 'XXXX-XXXX:DCIM'] or ['tree', 'primary:DCIM']
      final segments = uri.pathSegments;
      if (segments.length < 2) {
        return raw;
      }
      final treeId = segments.last;
      final colonIdx = treeId.indexOf(':');
      if (colonIdx < 0) {
        return raw;
      }
      final volume = treeId.substring(0, colonIdx);
      final rel = treeId.substring(colonIdx + 1);
      final base = volume == 'primary' ? '/storage/emulated/0' : '/storage/$volume';
      return rel.isEmpty ? base : '$base/$rel';
    } catch (_) {
      return raw;
    }
  }

  Future<void> _showManualEntry() async {
    final controller = TextEditingController(text: _selectedPath);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter Path'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '/storage/XXXX-XXXX/DCIM',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && mounted) {
      setState(() => _selectedPath = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final errorMessage = ref.watch(importSessionProvider.select((s) => s.errorMessage));
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Select Folder to Import', style: context.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Choose the folder on your memory card or USB drive that contains '
            'files to upload. Subfolders are included automatically.',
            style: context.textTheme.bodyMedium?.copyWith(
              color: context.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          if (errorMessage != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: context.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: context.colorScheme.onErrorContainer, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      errorMessage,
                      style: context.textTheme.bodySmall?.copyWith(
                        color: context.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _picking ? null : _browse,
            icon: _picking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.folder_open_rounded),
            label: const Text('Browse for Folder'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
          if (_selectedPath != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: context.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.folder_rounded, color: context.primaryColor, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _selectedPath!,
                      style: context.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Spacer(),
          OutlinedButton.icon(
            onPressed: _showManualEntry,
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Enter path manually'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _selectedPath != null
                ? () => _scanWithPermissionCheck(_selectedPath!)
                : null,
            icon: const Icon(Icons.search_rounded),
            label: const Text('Scan This Folder'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
        ],
      ),
    );
  }
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
    if (file.isTriggerFile) {
      badges.add('trigger');
    }
    if (file.isNativeImmichFile) {
      badges.add('also in Immich');
    }

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
