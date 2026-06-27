import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/copyparty/copyparty.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:share_plus/share_plus.dart';

/// The full multi-step "Import from Memory Card" flow.
///
/// Steps: directory picker → scan → options → progress → completion
class CopypartyImportPage extends ConsumerStatefulWidget {
  const CopypartyImportPage({super.key});

  @override
  ConsumerState<CopypartyImportPage> createState() => _CopypartyImportPageState();
}

class _CopypartyImportPageState extends ConsumerState<CopypartyImportPage> {
  // True when the user has chosen "Continue in background" — prevents the
  // didPop handler from calling reset() on the provider, which would kill
  // the ongoing upload.
  bool _backgroundLeave = false;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(importSessionProvider);
    final isUploading = session.step == ImportSessionStep.uploading;

    return PopScope(
      canPop: !isUploading,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          if (!_backgroundLeave) {
            ref.read(importSessionProvider.notifier).reset();
          }
          _backgroundLeave = false;
          return;
        }
        // Upload in progress — ask whether to continue in background
        if (!mounted) return;
        final continueInBg = await showDialog<bool>(
          context: context,
          builder: (dlgCtx) => AlertDialog(
            title: const Text('Upload in progress'),
            content: const Text(
              'Continue uploading in the background?\n\n'
              'The upload will finish even after you navigate away. '
              'Re-open "Import from Memory Card" to see the result.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dlgCtx, false),
                child: const Text('Stay'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dlgCtx, true),
                child: const Text('Continue in background'),
              ),
            ],
          ),
        );
        if (continueInBg == true && mounted) {
          _backgroundLeave = true;
          Navigator.of(context).pop();
          // Do NOT call reset() — upload continues, state persists.
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
                    child: SelectableText(
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
// Step 3: Options / scan results — checkboxes, folder info, destinations
// ---------------------------------------------------------------------------

class _OptionsStep extends ConsumerStatefulWidget {
  final ImportSessionState session;
  const _OptionsStep(this.session);

  @override
  ConsumerState<_OptionsStep> createState() => _OptionsStepState();
}

class _OptionsStepState extends ConsumerState<_OptionsStep> {
  late Set<String> _selectedPaths;
  final Map<String, UploadDestination> _destinationOverrides = {};

  @override
  void initState() {
    super.initState();
    _selectedPaths = widget.session.uploadSets
        .expand((s) => s.files)
        .where((f) => !f.alreadyUploaded)
        .map((f) => f.localPath)
        .toSet();
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

  void _setDestination(String path, UploadDestination dest) {
    setState(() => _destinationOverrides[path] = dest);
  }

  UploadDestination _destinationFor(UploadFile file) =>
      _destinationOverrides[file.localPath] ?? file.destination;

  void _applyDestinations() {
    for (final set in widget.session.uploadSets) {
      for (final file in set.files) {
        final override = _destinationOverrides[file.localPath];
        if (override != null) file.destination = override;
      }
    }
  }

  Future<void> _runSelfTest() async {
    final paths = _selectedPaths.toList();
    if (paths.isEmpty) return;

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Upload self-test'),
        content: Text(
          'This uploads each of the ${paths.length} selected '
          'file${paths.length == 1 ? '' : 's'} to copyparty several times under '
          'controlled variations:\n\n'
          '• original name + content\n'
          '• renamed (same content)\n'
          '• new name + changed content (brand-new identity)\n'
          '• new content into a fresh subfolder\n\n'
          'It records the server identity (wark) and whether each attempt '
          'completes, so the cause of failures can be seen directly. This may '
          'take a few minutes and uses bandwidth. Continue?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Run test')),
        ],
      ),
    );
    if (go != true || !mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 18),
            Expanded(child: Text('Running upload self-test…')),
          ],
        ),
      ),
    );

    List<UploadAttemptResult> results;
    try {
      results = await ref.read(importSessionProvider.notifier).runSelfTest(paths);
    } catch (e) {
      results = [];
      if (mounted) {
        Navigator.of(context).pop(); // close progress
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Self-test error: $e')),
        );
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // close progress

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Self-test results'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              results.isEmpty
                  ? 'No results.'
                  : results.map((r) => r.summaryLine).join('\n\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final logger = ref.read(copypartyLoggerProvider);
              final path = await logger.flush();
              final box = ctx.findRenderObject() as RenderBox?;
              await Share.shareXFiles(
                [XFile(path)],
                subject: 'Copyparty self-test log',
                sharePositionOrigin:
                    box != null ? box.localToGlobal(Offset.zero) & box.size : null,
              );
            },
            child: const Text('Share log'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
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
        Builder(
          builder: (ctx) {
            final alreadyCount = sets
                .expand((s) => s.files)
                .where((f) => f.alreadyUploaded)
                .length;
            if (alreadyCount == 0) return const SizedBox.shrink();
            return Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: ctx.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline,
                      size: 16,
                      color: ctx.colorScheme.onSecondaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$alreadyCount file${alreadyCount == 1 ? '' : 's'} already uploaded — unchecked by default.',
                      style: ctx.textTheme.bodySmall?.copyWith(
                        color: ctx.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        Expanded(
          child: ListView.builder(
            itemCount: sets.length,
            itemBuilder: (ctx, i) => _SelectableUploadSetTile(
              set: sets[i],
              rootPath: widget.session.directoryPath,
              selectedPaths: _selectedPaths,
              getDestination: _destinationFor,
              onToggleGroup: (select) => _toggleGroup(sets[i], select),
              onToggleFile: _toggleFile,
              onDestinationChange: _setDestination,
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: selectedCount > 0
                        ? () {
                            _applyDestinations();
                            ref
                                .read(importSessionProvider.notifier)
                                .startUpload(selectedFilePaths: Set.of(_selectedPaths));
                          }
                        : null,
                    icon: const Icon(Icons.upload_rounded),
                    label: Text(
                      'Upload $selectedCount file${selectedCount == 1 ? '' : 's'}',
                    ),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: selectedCount > 0 ? _runSelfTest : null,
                    icon: const Icon(Icons.science_outlined),
                    label: const Text('Run upload self-test (diagnostics)'),
                  ),
                ),
              ],
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
  final UploadDestination Function(UploadFile) getDestination;
  final void Function(bool) onToggleGroup;
  final void Function(String, bool) onToggleFile;
  final void Function(String, UploadDestination) onDestinationChange;

  const _SelectableUploadSetTile({
    required this.set,
    required this.rootPath,
    required this.selectedPaths,
    required this.getDestination,
    required this.onToggleGroup,
    required this.onToggleFile,
    required this.onDestinationChange,
  });

  @override
  Widget build(BuildContext context) {
    final filesSelected =
        set.files.where((f) => selectedPaths.contains(f.localPath)).length;
    final total = set.files.length;
    final bool? groupChecked =
        filesSelected == 0 ? false : (filesSelected == total ? true : null);
    final relPath = _relPathUtil(rootPath, set.directoryPath);

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
              destination: getDestination(f),
              onToggle: (v) => onToggleFile(f.localPath, v),
              onDestinationChange: (d) => onDestinationChange(f.localPath, d),
            ),
          )
          .toList(),
    );
  }

}

class _SelectableFileTile extends StatelessWidget {
  final UploadFile file;
  final bool selected;
  final UploadDestination destination;
  final void Function(bool) onToggle;
  final void Function(UploadDestination) onDestinationChange;

  const _SelectableFileTile({
    required this.file,
    required this.selected,
    required this.destination,
    required this.onToggle,
    required this.onDestinationChange,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.only(left: 16, right: 16),
          leading: Checkbox(
            value: selected,
            onChanged: (v) => onToggle(v ?? false),
          ),
          title: Text(file.filename, style: context.textTheme.bodyMedium),
          subtitle: Text(
            formatHumanReadableBytes(file.sizeBytes, 1),
            style: context.textTheme.bodySmall,
          ),
          trailing: file.isTriggerFile
              ? Icon(Icons.star_rounded, color: context.primaryColor, size: 20)
              : null,
          dense: true,
        ),
        if (file.alreadyUploaded)
          Padding(
            padding: const EdgeInsets.only(left: 72, bottom: 4),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline,
                    size: 13,
                    color: Colors.green.shade600),
                const SizedBox(width: 4),
                Text(
                  file.alreadyUploadedToImmich
                      ? 'Confirmed: copyparty + Immich'
                      : 'Confirmed: copyparty',
                  style: context.textTheme.labelSmall?.copyWith(
                    color: Colors.green.shade600,
                  ),
                ),
              ],
            ),
          ),
        // Destination selector — only for files Immich handles natively
        if (file.isNativeImmichFile && selected)
          Padding(
            padding: const EdgeInsets.only(left: 56, right: 16, bottom: 8),
            child: SegmentedButton<UploadDestination>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                textStyle: context.textTheme.labelSmall,
                visualDensity: VisualDensity.compact,
              ),
              segments: const [
                ButtonSegment(
                  value: UploadDestination.copypartyOnly,
                  label: Text('CP only'),
                  icon: Icon(Icons.cloud_upload_outlined, size: 14),
                ),
                ButtonSegment(
                  value: UploadDestination.both,
                  label: Text('Both'),
                  icon: Icon(Icons.sync_alt_rounded, size: 14),
                ),
                ButtonSegment(
                  value: UploadDestination.immichNative,
                  label: Text('Immich only'),
                  icon: Icon(Icons.photo_library_outlined, size: 14),
                ),
              ],
              selected: {destination},
              onSelectionChanged: (s) => onDestinationChange(s.first),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Step 4: Upload progress
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Step 4: Upload progress — Immich-style cards with speed + ETA
// ---------------------------------------------------------------------------

class _UploadProgressStep extends StatelessWidget {
  final ImportSessionState session;
  const _UploadProgressStep(this.session);

  @override
  Widget build(BuildContext context) {
    final allFiles = session.uploadSets.expand((s) => s.files).toList();
    final totalBytes = allFiles.fold<int>(0, (s, f) => s + f.sizeBytes);
    final doneBytes = allFiles.fold<int>(0, (s, f) => s + f.uploadedBytes);
    final activeCount = allFiles
        .where((f) =>
            f.status != UploadFileStatus.receiptWritten &&
            f.status != UploadFileStatus.failed &&
            !(f.status == UploadFileStatus.confirmed && !f.needsImmich))
        .length;

    return Column(
      children: [
        LinearProgressIndicator(
          value: session.totalFiles > 0
              ? session.completedFiles / session.totalFiles
              : null,
          minHeight: 4,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              _SectionBadge(
                label: 'Uploading',
                count: activeCount,
                color: context.colorScheme.primary,
              ),
              const Spacer(),
              Text(
                '${session.completedFiles} / ${session.totalFiles} files  '
                '${formatHumanReadableBytes(doneBytes, 1)} / '
                '${formatHumanReadableBytes(totalBytes, 1)}',
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: session.uploadSets.length,
            itemBuilder: (ctx, i) =>
                _ProgressSetSection(set: session.uploadSets[i]),
          ),
        ),
      ],
    );
  }
}

class _SectionBadge extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  const _SectionBadge({required this.label, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: context.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w600, color: color),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '$count',
            style: context.textTheme.labelSmall
                ?.copyWith(fontWeight: FontWeight.bold, color: color),
          ),
        ),
      ],
    );
  }
}

class _ProgressSetSection extends StatelessWidget {
  final UploadSet set;
  const _ProgressSetSection({required this.set});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  set.displayName,
                  style: context.textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                formatHumanReadableBytes(set.totalBytes, 1),
                style: context.textTheme.labelSmall?.copyWith(
                  color: context.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
        ...set.files.map((f) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ProgressFileCard(file: f),
            )),
        const SizedBox(height: 4),
      ],
    );
  }
}

class _ProgressFileCard extends StatefulWidget {
  final UploadFile file;
  const _ProgressFileCard({required this.file});

  @override
  State<_ProgressFileCard> createState() => _ProgressFileCardState();
}

class _ProgressFileCardState extends State<_ProgressFileCard> {
  final _speedCalc = UploadSpeedCalculator();
  String _speed = '-- MB/s';
  String _eta = '--:--';

  @override
  void didUpdateWidget(_ProgressFileCard old) {
    super.didUpdateWidget(old);
    if (widget.file.uploadedBytes != old.file.uploadedBytes) {
      _speedCalc.update(widget.file.uploadedBytes, widget.file.sizeBytes);
      _speed = _speedCalc.speedAsString;
      _eta = _speedCalc.timeRemainingAsString;
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final isDone = file.status == UploadFileStatus.receiptWritten ||
        (file.status == UploadFileStatus.confirmed && !file.needsImmich);
    final isFailed = file.status == UploadFileStatus.failed;
    final isActive = !isDone && !isFailed;

    final cardColor = isFailed
        ? context.colorScheme.errorContainer
        : isDone
            ? context.colorScheme.surfaceContainerLow
            : context.colorScheme.primaryContainer.withValues(alpha: 0.5);
    final borderColor = isFailed
        ? context.colorScheme.error.withValues(alpha: 0.3)
        : isDone
            ? context.colorScheme.outline.withValues(alpha: 0.15)
            : context.colorScheme.primary.withValues(alpha: 0.3);

    return Card(
      elevation: 0,
      color: cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _FileTypeIcon(filename: file.filename, isDone: isDone, isFailed: isFailed),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    file.filename,
                    style: context.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isFailed
                        ? file.errorMessage ?? 'Upload failed'
                        : isDone
                            ? '${formatHumanReadableBytes(file.sizeBytes, 1)} · Done'
                            : '${formatHumanReadableBytes(file.sizeBytes, 1)} · '
                              '${formatHumanReadableBytes(file.uploadedBytes, 1)} transferred · '
                              '$_speed',
                    style: context.textTheme.labelLarge?.copyWith(
                      color: isFailed
                          ? context.colorScheme.error
                          : context.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (isActive && file.sizeBytes > 0) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: file.progress,
                        backgroundColor:
                            context.colorScheme.primary.withValues(alpha: 0.2),
                        valueColor: AlwaysStoppedAnimation(
                          context.colorScheme.primary,
                        ),
                        minHeight: 4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 56,
              child: isFailed
                  ? Icon(Icons.error_rounded,
                      color: context.colorScheme.error, size: 28)
                  : isDone
                      ? Icon(Icons.check_circle_rounded,
                          color: Colors.green, size: 28)
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${(file.progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
                              textAlign: TextAlign.right,
                              style: context.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: context.colorScheme.primary,
                              ),
                            ),
                            if (_eta != '--:--')
                              Text(
                                'est $_eta',
                                textAlign: TextAlign.right,
                                style: context.textTheme.labelSmall?.copyWith(
                                  color: context.colorScheme.onSurface
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileTypeIcon extends StatelessWidget {
  final String filename;
  final bool isDone;
  final bool isFailed;

  const _FileTypeIcon({
    required this.filename,
    required this.isDone,
    required this.isFailed,
  });

  static IconData _iconFor(String name) {
    final ext = name.toLowerCase().split('.').last;
    return switch (ext) {
      'jpg' || 'jpeg' || 'png' || 'heic' || 'heif' || 'webp' => Icons.image_rounded,
      'mp4' || 'mov' || 'lrv' || 'avi' || 'mkv' => Icons.videocam_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = isFailed
        ? context.colorScheme.error
        : isDone
            ? Colors.green
            : context.colorScheme.primary;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(_iconFor(filename), size: 24, color: color),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 5: Completion
// ---------------------------------------------------------------------------

class _CompletionStep extends ConsumerStatefulWidget {
  final ImportSessionState session;
  const _CompletionStep(this.session);

  @override
  ConsumerState<_CompletionStep> createState() => _CompletionStepState();
}

class _CompletionStepState extends ConsumerState<_CompletionStep> {
  late Set<String> _checkedForDeletion;

  @override
  void initState() {
    super.initState();
    _checkedForDeletion = widget.session.uploadSets
        .expand((s) => s.files)
        .where((f) => f.safeToDelete)
        .map((f) => f.localPath)
        .toSet();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(importSessionProvider);
    final allFiles = session.uploadSets.expand((s) => s.files).toList();

    final cpSucceeded = allFiles.where((f) => f.copypartyConfirmed).length;
    final cpNeeded = allFiles.where((f) => f.needsCopyparty).length;
    final imSucceeded = allFiles.where((f) => f.immichConfirmed).length;
    final imNeeded = allFiles.where((f) => f.needsImmich).length;
    final failed = allFiles.where((f) => f.status == UploadFileStatus.failed).length;
    final hasErrors = failed > 0 || cpSucceeded < cpNeeded;

    final checkedFiles = allFiles
        .where((f) => _checkedForDeletion.contains(f.localPath))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header banner
        Container(
          color: hasErrors
              ? context.colorScheme.errorContainer
              : context.colorScheme.primaryContainer,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Row(
            children: [
              Icon(
                hasErrors
                    ? Icons.warning_rounded
                    : Icons.check_circle_rounded,
                color: hasErrors
                    ? context.colorScheme.onErrorContainer
                    : context.colorScheme.onPrimaryContainer,
                size: 26,
              ),
              const SizedBox(width: 10),
              Text(
                hasErrors ? 'Completed with errors' : 'Upload Complete',
                style: context.textTheme.titleLarge?.copyWith(
                  color: hasErrors
                      ? context.colorScheme.onErrorContainer
                      : context.colorScheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
        // Stats chips
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Wrap(
            spacing: 12,
            children: [
              _StatChip(
                icon: Icons.cloud_done_rounded,
                label: 'CP $cpSucceeded/$cpNeeded',
                ok: cpSucceeded == cpNeeded,
              ),
              if (imNeeded > 0)
                _StatChip(
                  icon: Icons.photo_library_rounded,
                  label: 'Immich $imSucceeded/$imNeeded',
                  ok: imSucceeded == imNeeded,
                ),
              if (failed > 0)
                _StatChip(
                  icon: Icons.error_outline_rounded,
                  label: '$failed failed',
                  ok: false,
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Per-group file list
        Expanded(
          child: ListView.builder(
            itemCount: session.uploadSets.length,
            itemBuilder: (ctx, i) {
              final set = session.uploadSets[i];
              return _CompletionSetSection(
                set: set,
                rootPath: session.directoryPath,
                checkedForDeletion: _checkedForDeletion,
                onToggle: (path, v) => setState(() {
                  if (v) {
                    _checkedForDeletion.add(path);
                  } else {
                    _checkedForDeletion.remove(path);
                  }
                }),
              );
            },
          ),
        ),
        // Footer
        const Divider(height: 1),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (checkedFiles.isNotEmpty) ...[
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _confirmDelete(context, ref, checkedFiles),
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: Text(
                        'Delete ${checkedFiles.length} selected '
                        'file${checkedFiles.length == 1 ? '' : 's'}',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _shareDiagnosticLog(context, ref),
                    icon: const Icon(Icons.bug_report_outlined),
                    label: const Text('Share diagnostic log'),
                  ),
                ),
                const SizedBox(height: 8),
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
          ),
        ),
      ],
    );
  }

  Future<void> _shareDiagnosticLog(BuildContext context, WidgetRef ref) async {
    final logger = ref.read(copypartyLoggerProvider);
    final path = await logger.flush();
    final box = context.findRenderObject() as RenderBox?;
    await Share.shareXFiles(
      [XFile(path)],
      subject: 'Copyparty diagnostic log',
      sharePositionOrigin:
          box != null ? box.localToGlobal(Offset.zero) & box.size : null,
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
          'Delete ${files.length} file${files.length == 1 ? '' : 's'} '
          'from the memory card?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: ctx.colorScheme.error,
            ),
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
          SnackBar(
            content: Text(
              'Deleted $deleted / ${files.length} '
              'file${files.length == 1 ? '' : 's'}',
            ),
          ),
        );
      }
    }
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool ok;
  const _StatChip({required this.icon, required this.label, required this.ok});

  @override
  Widget build(BuildContext context) {
    final color = ok ? context.colorScheme.primary : context.colorScheme.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: context.textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
  }
}

class _CompletionSetSection extends StatelessWidget {
  final UploadSet set;
  final String? rootPath;
  final Set<String> checkedForDeletion;
  final void Function(String, bool) onToggle;

  const _CompletionSetSection({
    required this.set,
    required this.rootPath,
    required this.checkedForDeletion,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final relPath = _relPathUtil(rootPath, set.directoryPath);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                set.displayName,
                style: context.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (relPath.isNotEmpty)
                Text(
                  relPath,
                  style: context.textTheme.bodySmall?.copyWith(
                    color:
                        context.colorScheme.onSurface.withValues(alpha: 0.5),
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        ...set.files.map(
          (f) => _CompletionFileTile(
            file: f,
            checked: checkedForDeletion.contains(f.localPath),
            onToggle: (v) => onToggle(f.localPath, v),
          ),
        ),
        const Divider(height: 8),
      ],
    );
  }
}

class _CompletionFileTile extends StatelessWidget {
  final UploadFile file;
  final bool checked;
  final void Function(bool) onToggle;

  const _CompletionFileTile({
    required this.file,
    required this.checked,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cpOk = file.copypartyConfirmed;
    final imOk = file.immichConfirmed;
    final failed = file.status == UploadFileStatus.failed;
    final skipped = file.status == UploadFileStatus.pending;

    Widget cpIcon = const SizedBox.shrink();
    if (file.needsCopyparty) {
      if (cpOk) {
        cpIcon = const Icon(Icons.cloud_done_rounded,
            size: 16, color: Colors.green);
      } else if (failed || (!skipped && !cpOk)) {
        cpIcon = Icon(Icons.cloud_off_rounded,
            size: 16, color: context.colorScheme.error);
      } else {
        cpIcon = Icon(Icons.cloud_outlined,
            size: 16,
            color: context.colorScheme.onSurface.withValues(alpha: 0.3));
      }
    }

    Widget imIcon = const SizedBox.shrink();
    if (file.needsImmich) {
      if (imOk) {
        imIcon = const Icon(Icons.photo_library_rounded,
            size: 16, color: Colors.green);
      } else if (failed || (!skipped && !imOk)) {
        imIcon = Icon(Icons.image_not_supported_rounded,
            size: 16, color: context.colorScheme.error);
      } else {
        imIcon = Icon(Icons.photo_library_outlined,
            size: 16,
            color: context.colorScheme.onSurface.withValues(alpha: 0.3));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 8, right: 16),
          leading: Checkbox(
            value: checked,
            onChanged: (v) => onToggle(v ?? false),
          ),
          title: Text(
            file.filename,
            style: context.textTheme.bodyMedium?.copyWith(
              color: skipped
                  ? context.colorScheme.onSurface.withValues(alpha: 0.4)
                  : null,
            ),
          ),
          subtitle: skipped
              ? Text(
                  'Skipped',
                  style: context.textTheme.bodySmall?.copyWith(
                    color:
                        context.colorScheme.onSurface.withValues(alpha: 0.3),
                  ),
                )
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              cpIcon,
              if (file.needsImmich) ...[
                const SizedBox(width: 6),
                imIcon,
              ],
              const SizedBox(width: 8),
              Text(
                formatHumanReadableBytes(file.sizeBytes, 1),
                style: context.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        if (failed && file.errorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 16, 4),
            child: SelectableText(
              file.errorMessage!,
              style: context.textTheme.bodySmall
                  ?.copyWith(color: context.colorScheme.error),
            ),
          ),
      ],
    );
  }
}

String _relPathUtil(String? root, String? dir) {
  if (dir == null) return '';
  if (root == null) return dir.split('/').last;
  if (dir == root) return dir.split('/').last;
  if (dir.startsWith('$root/')) return dir.substring(root.length + 1);
  return dir.split('/').last;
}
