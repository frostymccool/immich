import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
// Step 1: Folder picker — browse and scan in one tap
// ---------------------------------------------------------------------------

class _DirectoryPickerStep extends ConsumerStatefulWidget {
  const _DirectoryPickerStep();

  @override
  ConsumerState<_DirectoryPickerStep> createState() => _DirectoryPickerStepState();
}

class _DirectoryPickerStepState extends ConsumerState<_DirectoryPickerStep> {
  static const _safChannel = MethodChannel('immich/saf_picker');

  String? _selectedPath;
  bool _picking = false;

  Future<void> _browse() async {
    setState(() => _picking = true);
    try {
      final path = await _safChannel.invokeMethod<String?>('pickDirectory');
      if (path != null && mounted) {
        setState(() => _selectedPath = path);
        await _scanWithPermissionCheck(path);
      }
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Picker error: ${e.message}')),
        );
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
        if (!mounted) return;
        final goToSettings = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('All Files Access Required'),
            content: const Text(
              'Scanning USB drives and SD cards requires '
              '"All files access" (MANAGE_EXTERNAL_STORAGE).\n\n'
              'Open Settings → Apps → Immich → Permissions → Files and media → '
              'Allow management of all files.\n\n'
              'This is a one-time step.',
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
            'files to upload. Subfolders are included automatically.\n\n'
            'If multiple USB devices are connected, the picker will show all of '
            'them — tap the device that contains your files, then navigate to '
            'the desired folder.',
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
// Step 3: Options / scan results — with checkboxes and folder info
// ---------------------------------------------------------------------------

class _OptionsStep extends ConsumerStatefulWidget {
  final ImportSessionState session;
  const _OptionsStep(this.session);

  @override
  ConsumerState<_OptionsStep> createState() => _OptionsStepState();
}

class _OptionsStepState extends ConsumerState<_OptionsStep> {
  late Set<String> _selectedPaths;

  @override
  void initState() {
    super.initState();
    _selectedPaths = _allPaths(widget.session.uploadSets);
  }

  Set<String> _allPaths(List<UploadSet> sets) =>
      sets.expand((s) => s.files).map((f) => f.localPath).toSet();

  void _toggleAll(bool select) {
    setState(() {
      _selectedPaths = select ? _allPaths(widget.session.uploadSets) : {};
    });
  }

  void _toggleGroup(UploadSet set, bool select) {
    setState(() {
      for (final f in set.files) {
        if (select) {
          _selectedPaths.add(f.localPath);
        } else {
          _selectedPaths.remove(f.localPath);
        }
      }
    });
  }

  void _toggleFile(String path, bool select) {
    setState(() {
      if (select) {
        _selectedPaths.add(path);
      } else {
        _selectedPaths.remove(path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sets = widget.session.uploadSets;

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

    final allFiles = sets.expand((s) => s.files).toList();
    final totalFiles = allFiles.length;
    final selectedCount =
        allFiles.where((f) => _selectedPaths.contains(f.localPath)).length;
    final selectedBytes = allFiles
        .where((f) => _selectedPaths.contains(f.localPath))
        .fold<int>(0, (s, f) => s + f.sizeBytes);
    final allSelected = selectedCount == totalFiles;

    return Column(
      children: [
        // Summary bar with select-all toggle
        Container(
          color: context.colorScheme.surfaceContainer,
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.file_copy_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$selectedCount / $totalFiles files '
                  '(${formatHumanReadableBytes(selectedBytes, 1)})',
                  style: context.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
              TextButton(
                onPressed: () => _toggleAll(!allSelected),
                child: Text(allSelected ? 'Deselect All' : 'Select All'),
              ),
            ],
          ),
        ),
        // Upload set list
        Expanded(
          child: ListView.builder(
            itemCount: sets.length,
            itemBuilder: (ctx, i) => _SelectableUploadSetTile(
              set: sets[i],
              rootPath: widget.session.directoryPath,
              selectedPaths: _selectedPaths,
              onToggleGroup: (select) => _toggleGroup(sets[i], select),
              onToggleFile: _toggleFile,
            ),
          ),
        ),
        // Upload button
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: selectedCount > 0
                    ? () => ref
                        .read(importSessionProvider.notifier)
                        .startUpload(selectedFilePaths: Set.of(_selectedPaths))
                    : null,
                icon: const Icon(Icons.upload_rounded),
                label: Text(
                  'Upload $selectedCount file${selectedCount == 1 ? '' : 's'}',
                ),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SelectableUploadSetTile extends StatelessWidget {
  final UploadSet set;
  final String? rootPath;
  final Set<String> selectedPaths;
  final void Function(bool) onToggleGroup;
  final void Function(String, bool) onToggleFile;

  const _SelectableUploadSetTile({
    required this.set,
    required this.rootPath,
    required this.selectedPaths,
    required this.onToggleGroup,
    required this.onToggleFile,
  });

  @override
  Widget build(BuildContext context) {
    final filesSelected =
        set.files.where((f) => selectedPaths.contains(f.localPath)).length;
    final total = set.files.length;
    final bool? groupChecked =
        filesSelected == 0 ? false : (filesSelected == total ? true : null);

    final relPath = _relPath(rootPath, set.directoryPath);

    return ExpansionTile(
      leading: Checkbox(
        tristate: true,
        value: groupChecked,
        onChanged: (v) => onToggleGroup(v == true),
      ),
      title: Text(set.displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (relPath.isNotEmpty)
            Text(
              relPath,
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colorScheme.onSurface.withValues(alpha: 0.5),
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          Text(
            '$total file${total == 1 ? '' : 's'} · '
            '${formatHumanReadableBytes(set.totalBytes, 1)}',
          ),
        ],
      ),
      children: set.files
          .map(
            (f) => _SelectableFileTile(
              file: f,
              selected: selectedPaths.contains(f.localPath),
              onToggle: (v) => onToggleFile(f.localPath, v),
            ),
          )
          .toList(),
    );
  }

  String _relPath(String? root, String? dir) {
    if (dir == null) return '';
    if (root == null) return dir.split('/').last;
    if (dir == root) return dir.split('/').last;
    if (dir.startsWith('$root/')) return dir.substring(root.length + 1);
    return dir.split('/').last;
  }
}

class _SelectableFileTile extends StatelessWidget {
  final UploadFile file;
  final bool selected;
  final void Function(bool) onToggle;

  const _SelectableFileTile({
    required this.file,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final badges = <String>[];
    if (file.isTriggerFile) badges.add('trigger');
    if (file.isNativeImmichFile) badges.add('also in Immich');

    return ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 16),
      leading: Checkbox(
        value: selected,
        onChanged: (v) => onToggle(v ?? false),
      ),
      title: Text(file.filename, style: context.textTheme.bodyMedium),
      subtitle: Text(
        [formatHumanReadableBytes(file.sizeBytes, 1), ...badges].join(' · '),
        style: context.textTheme.bodySmall,
      ),
      trailing: file.isTriggerFile
          ? Icon(Icons.star_rounded, color: context.primaryColor, size: 20)
          : null,
      dense: true,
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
                  allFiles.fold<int>(0, (s, f) => s + f.uploadedBytes),
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
              style: context.textTheme.bodySmall
                  ?.copyWith(color: context.colorScheme.error),
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
    final succeeded =
        allFiles.where((f) => f.status == UploadFileStatus.receiptWritten).length;
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
                failed == 0
                    ? Icons.check_circle_rounded
                    : Icons.warning_rounded,
                color: failed == 0
                    ? context.primaryColor
                    : context.colorScheme.error,
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
          if (failed > 0)
            _SummaryRow('Failed', '$failed files', isError: true),
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

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    List<UploadFile> files,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Source Files'),
        content: Text(
          'Delete ${files.length} files from the memory card? '
          'All files have been uploaded and verified.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
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
