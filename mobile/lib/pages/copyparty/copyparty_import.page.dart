import 'dart:io';

import 'package:flutter/material.dart';
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
          ImportSessionStep.scanning => const _ScanningStep(),
          ImportSessionStep.options => _OptionsStep(session),
          ImportSessionStep.uploading => _UploadProgressStep(session),
          ImportSessionStep.complete => _CompletionStep(session),
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 1: Directory picker
// ---------------------------------------------------------------------------

class _DirectoryPickerStep extends ConsumerStatefulWidget {
  const _DirectoryPickerStep();

  @override
  ConsumerState<_DirectoryPickerStep> createState() => _DirectoryPickerStepState();
}

class _DirectoryPickerStepState extends ConsumerState<_DirectoryPickerStep> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    final path = _controller.text.trim();
    if (path.isEmpty) {
      setState(() => _error = 'Please enter a directory path');
      return;
    }
    final dir = Directory(path);
    if (!await dir.exists()) {
      setState(() => _error = 'Directory not found: $path');
      return;
    }
    setState(() => _error = null);
    ref.read(importSessionProvider.notifier).scan(path);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Select Memory Card Directory',
            style: context.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Enter the path to your memory card DCIM folder. '
            'On Android, this is usually /storage/sdcard1/DCIM or '
            '/storage/emulated/0/DCIM for internal storage.',
            style: context.textTheme.bodyMedium?.copyWith(
              color: context.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: 'Directory path',
              hintText: '/storage/sdcard1/DCIM',
              border: const OutlineInputBorder(),
              errorText: _error,
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () => _controller.clear(),
              ),
            ),
            onSubmitted: (_) => _startScan(),
          ),
          const SizedBox(height: 8),
          // Quick path shortcuts
          Wrap(
            spacing: 8,
            children: [
              _PathChip(label: 'Internal DCIM', path: '/storage/emulated/0/DCIM', controller: _controller),
              _PathChip(label: 'SD Card DCIM', path: '/storage/sdcard1/DCIM', controller: _controller),
              _PathChip(label: 'Downloads', path: '/storage/emulated/0/Download', controller: _controller),
            ],
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.search_rounded),
              label: const Text('Scan for Files'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
          ),
        ],
      ),
    );
  }
}

class _PathChip extends StatelessWidget {
  final String label;
  final String path;
  final TextEditingController controller;

  const _PathChip({required this.label, required this.path, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      onPressed: () => controller.text = path,
    );
  }
}

// ---------------------------------------------------------------------------
// Step 2: Scanning
// ---------------------------------------------------------------------------

class _ScanningStep extends StatelessWidget {
  const _ScanningStep();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator.adaptive(),
          SizedBox(height: 24),
          Text('Scanning directory for files…'),
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
