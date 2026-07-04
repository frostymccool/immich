import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/copyparty/copyparty.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/services/copyparty/copyparty_file_pairer.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';
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
  static const _safChannel = MethodChannel('immich/saf_picker');

  /// Item 2: pick another folder and append it to the active upload queue.
  Future<void> _pickAndAddFolder() async {
    try {
      final path = await _safChannel.invokeMethod<String?>('pickDirectory');
      if (path != null) {
        await ref.read(importSessionProvider.notifier).addFolders([path]);
      }
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Picker error: ${e.message}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(importSessionProvider);
    final isUploading = session.step == ImportSessionStep.uploading;

    // FB6: no "stay / continue in background" dialog. While uploading, allow the
    // pop and just let it continue in the background (don't reset the session).
    // When not uploading, popping resets the session for a clean next run.
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !isUploading) {
          ref.read(importSessionProvider.notifier).reset();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Import from Memory Card'),
          centerTitle: false,
        ),
        // Q4: SelectionArea makes all the text on these pages long-press
        // selectable + copyable (helpful for support / sharing values).
        body: SelectionArea(
          child: switch (session.step) {
            ImportSessionStep.idle => const _DirectoryPickerStep(),
            ImportSessionStep.scanning => _ScanningStep(session),
            ImportSessionStep.options => _OptionsStep(session),
            ImportSessionStep.uploading => _UploadProgressStep(
                session,
                onCancel: () => ref.read(importSessionProvider.notifier).cancelUpload(),
                onAddFolders: _pickAndAddFolder,
              ),
            ImportSessionStep.complete => _CompletionStep(session),
          },
        ),
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

  bool _verifying = false;
  bool _verifyFailed = false;
  bool _userTouched = false;

  // Cancellation for the background Immich-by-checksum pass: it hashes every
  // native file on the card, so leaving the picker or starting a new verify
  // must stop the in-flight pass rather than let it keep reading the card and
  // mutating shared UploadFile.verification objects. Each _verify() run bumps
  // the generation; a loop iteration bails the moment its generation is stale
  // or the widget is disposed. (Adversarial review HIGH 2/3)
  bool _disposed = false;
  int _verifyGeneration = 0;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // FB3: don't block — show everything ticked immediately, then verify
    // status lazily against the server. Default selection is refined once
    // verification lands (unless the user has already changed it).
    _selectedPaths = _allPaths(widget.session.uploadSets);
    WidgetsBinding.instance.addPostFrameCallback((_) => _verify());
  }

  /// True when live verification says a file with this name AND size is already
  /// on the server (hash not necessarily checked).
  static bool _looksPresent(UploadFile f) {
    final v = f.verification;
    return v != null &&
        v.filenamePresent == VerifyState.yes &&
        v.sizeMatches == VerifyState.yes &&
        v.partialExists != VerifyState.yes;
  }

  /// Lazily verify all files against the server (FB3/FB4): one folder listing
  /// for name/size/partial, then a background per-file Immich-by-checksum pass.
  /// On a network failure, surfaces an offline state + Refresh.
  Future<void> _verify() async {
    if (_verifying) return;
    // Invalidate any background Immich pass still running from a prior _verify.
    final generation = ++_verifyGeneration;
    setState(() {
      _verifying = true;
      _verifyFailed = false;
    });
    final config = ref.read(appConfigProvider).copyparty;
    final uploader = ref.read(copypartyUploaderProvider);
    final files = widget.session.uploadSets.expand((s) => s.files).toList();
    final rootDir = widget.session.directoryPath;
    // Each file's expected server folder — the mirrored sub-path when "recreate
    // folder structure" is on, else the flat base. Verifying against the base
    // when a file was uploaded into a subfolder wrongly reports it "missing".
    String targetFolder(UploadFile f) => config.recreateFolderStructure
        ? mirroredUploadPath(config.uploadPath, rootDir, f.localPath)
        : config.uploadPath;
    String password = '';
    try {
      password = await ref.read(copypartyPasswordProvider.future);
    } catch (_) {}

    try {
      // List each distinct target folder once, then match files to their folder.
      final folders = files.map(targetFolder).toSet();
      final listings = <String, Map<String, int>>{};
      for (final folder in folders) {
        try {
          listings[folder] =
              await uploader.listUploadFolder(config.hostUrl, folder, password);
        } on CopypartyUploadException {
          // A folder-level HTTP error (e.g. this target folder doesn't exist on
          // the server yet) means "no files here", NOT that copyparty is
          // unreachable. Treat it as empty so the files show as not-present and
          // upload normally — only a genuine CONNECTION failure (which is not a
          // CopypartyUploadException) trips the offline banner below.
          listings[folder] = const <String, int>{};
        }
      }
      for (final f in files) {
        f.verification = CopypartyUploaderService.verificationFromListing(
          listings[targetFolder(f)] ?? const {},
          f.filename,
          f.sizeBytes,
          immichApplicable: CopypartyFilePairer.isNativeImmichFilename(f.filename),
        );
      }
      if (!mounted) return;
      setState(() {
        _verifying = false;
        if (!_userTouched) {
          _selectedPaths =
              files.where((f) => !_looksPresent(f)).map((f) => f.localPath).toSet();
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _verifyFailed = true;
      });
      return;
    }

    // Background Immich-by-checksum pass for native-Immich files (FB4); rows
    // update as each completes. Skipped if the listing failed above.
    final api = ref.read(apiServiceProvider).assetsApi;
    for (final f in files) {
      // Bail immediately if disposed or a newer _verify run superseded us — do
      // NOT start hashing the next (possibly multi-GB) file.
      if (_disposed || generation != _verifyGeneration) return;
      if (!CopypartyFilePairer.isNativeImmichFilename(f.filename)) continue;
      try {
        final id = await immichAssetIdByChecksum(api, f.localPath);
        // Re-check after the await: the user may have left or refreshed while
        // this file was hashing. Don't mutate shared state for a stale run.
        if (_disposed || generation != _verifyGeneration) return;
        f.verification = (f.verification ?? const ServerFileVerification()).copyWith(
          immich: id != null ? VerifyState.yes : VerifyState.no,
          immichApplicable: true,
        );
        // Item 2: if Immich already has this file, there's no point re-uploading
        // to Immich — default its destination to "CP only" (unless the user has
        // already picked one for it).
        if (id != null && !_destinationOverrides.containsKey(f.localPath)) {
          _destinationOverrides[f.localPath] = UploadDestination.copypartyOnly;
        }
        if (mounted) setState(() {});
      } catch (_) {}
    }
  }

  Set<String> _allPaths(List<UploadSet> sets) =>
      sets.expand((s) => s.files).map((f) => f.localPath).toSet();

  void _toggleAll(bool select) {
    setState(() {
      _userTouched = true;
      _selectedPaths = select ? _allPaths(widget.session.uploadSets) : {};
    });
  }

  void _toggleGroup(UploadSet set, bool select) {
    setState(() {
      _userTouched = true;
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
      _userTouched = true;
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

  Future<void> _runVerificationSelfTest() async {
    final paths = _selectedPaths.toList();
    if (paths.isEmpty) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 18),
            Expanded(child: Text('Verifying selected files…')),
          ],
        ),
      ),
    );
    List<String> lines;
    try {
      lines = await ref.read(importSessionProvider.notifier).runVerificationSelfTest(paths);
    } catch (e) {
      lines = ['error: $e'];
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // close progress
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verification self-test'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              lines.isEmpty ? 'No results.' : lines.join('\n\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final path = await ref.read(copypartyLoggerProvider).flush();
              final box = ctx.findRenderObject() as RenderBox?;
              await Share.shareXFiles(
                [XFile(path)],
                subject: 'Copyparty verification self-test',
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
    // Mirror the upload order in the picker: when "upload smallest first" is on,
    // show groups sorted by total size (a sorted copy — session order untouched).
    final sortSmallest =
        ref.watch(appConfigProvider.select((c) => c.copyparty.sortSmallestFirst));
    final debugMode =
        ref.watch(appConfigProvider.select((c) => c.copyparty.debugMode));
    final sets = sortSmallest
        ? (List<UploadSet>.of(widget.session.uploadSets)
          ..sort((a, b) => a.totalBytes.compareTo(b.totalBytes)))
        : widget.session.uploadSets;

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
    final selectedFiles =
        allFiles.where((f) => _selectedPaths.contains(f.localPath)).toList();
    final selectedCount = selectedFiles.length;
    final selectedBytes = selectedFiles.fold<int>(0, (s, f) => s + f.sizeBytes);
    final allSelected = selectedCount == totalFiles;
    // Item 3: destination breakdown, shown inline only when the selection isn't
    // uniformly "Both" (no point otherwise). Kept on the same header line.
    final cpCount = selectedFiles
        .where((f) => _destinationFor(f) != UploadDestination.immichNative)
        .length;
    final immichCount = selectedFiles
        .where((f) => _destinationFor(f) != UploadDestination.copypartyOnly)
        .length;
    final allBoth = selectedFiles.isNotEmpty &&
        selectedFiles.every((f) => _destinationFor(f) == UploadDestination.both);

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
                  '(${formatHumanReadableBytes(selectedBytes, 1)})'
                  '${allBoth ? '' : '  ·  CP $cpCount · Immich $immichCount'}',
                  style: context.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () => _toggleAll(!allSelected),
                child: Text(allSelected ? 'Deselect All' : 'Select All'),
              ),
            ],
          ),
        ),
        // FB3/FB4: lazy verify status banner — checking / offline + Refresh.
        if (_verifying)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text('Checking server…', style: context.textTheme.bodySmall),
              ],
            ),
          )
        else if (_verifyFailed)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: BoxDecoration(
              color: context.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.cloud_off_rounded,
                    size: 18, color: context.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Couldn\'t reach copyparty — upload status unknown.',
                    style: context.textTheme.bodySmall
                        ?.copyWith(color: context.colorScheme.onErrorContainer),
                  ),
                ),
                TextButton(
                  onPressed: _verify,
                  child: const Text('Refresh'),
                ),
              ],
            ),
          ),
        Builder(
          builder: (ctx) {
            final alreadyCount = sets
                .expand((s) => s.files)
                .where(_OptionsStepState._looksPresent)
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
                      '$alreadyCount file${alreadyCount == 1 ? '' : 's'} already on the server by name+size (hash not checked) — unchecked by default.',
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
                // Q1: show where these files will be uploaded before starting.
                const _DestinationBanner(),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: selectedCount > 0
                        ? () {
                            _applyDestinations();
                            ref
                                .read(importSessionProvider.notifier)
                                .startUpload(
                                  selectedFilePaths: Set.of(_selectedPaths),
                                );
                          }
                        : null,
                    icon: const Icon(Icons.upload_rounded),
                    label: Text(
                      'Upload $selectedCount file${selectedCount == 1 ? '' : 's'}',
                    ),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  ),
                ),
                // Self-test/diagnostic actions only when debug mode is on. (item 5)
                if (debugMode) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: selectedCount > 0 ? _runSelfTest : null,
                      icon: const Icon(Icons.science_outlined),
                      label: const Text('Run upload self-test (diagnostics)'),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: selectedCount > 0 ? _runVerificationSelfTest : null,
                      icon: const Icon(Icons.fact_check_outlined, size: 18),
                      label: const Text('Run verification self-test'),
                    ),
                  ),
                ],
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

  Widget _relPathLine(BuildContext context, String relPath) => Text(
        relPath,
        style: context.textTheme.bodySmall?.copyWith(
          color: context.colorScheme.onSurface.withValues(alpha: 0.5),
          fontFamily: 'monospace',
        ),
        overflow: TextOverflow.ellipsis,
      );

  @override
  Widget build(BuildContext context) {
    final relPath = _relPathUtil(rootPath, set.directoryPath);
    final total = set.files.length;

    // Item 2: a single-file "group" is just that file — render it directly with
    // its status chips visible, so there's nothing to expand.
    if (total == 1) {
      final f = set.files.first;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (relPath.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 6),
              child: _relPathLine(context, relPath),
            ),
          _SelectableFileTile(
            file: f,
            selected: selectedPaths.contains(f.localPath),
            destination: getDestination(f),
            onToggle: (v) => onToggleFile(f.localPath, v),
            onDestinationChange: (d) => onDestinationChange(f.localPath, d),
          ),
        ],
      );
    }

    final filesSelected =
        set.files.where((f) => selectedPaths.contains(f.localPath)).length;
    final bool? groupChecked =
        filesSelected == 0 ? false : (filesSelected == total ? true : null);

    return ExpansionTile(
      leading: Checkbox(
        tristate: true,
        value: groupChecked,
        onChanged: (v) => onToggleGroup(v == true),
      ),
      // Item 3: show the file count right in the group entry.
      title: Text('${set.displayName}  ·  $total files'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (relPath.isNotEmpty) _relPathLine(context, relPath),
          Text(formatHumanReadableBytes(set.totalBytes, 1)),
          // Item 1: rolled-up status so it's visible without expanding.
          _GroupSummary(set: set),
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

/// Item 1: a compact roll-up of the group's per-file verification — e.g.
/// "name 1/2 · size 2/2 · Immich 2/2" — shown on the collapsed group header so
/// mixed states are visible without expanding.
class _GroupSummary extends StatelessWidget {
  final UploadSet set;
  const _GroupSummary({required this.set});

  @override
  Widget build(BuildContext context) {
    final files = set.files;
    if (files.every((f) => f.verification == null)) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('checking server…',
            style: context.textTheme.labelSmall?.copyWith(
              color: context.colorScheme.onSurfaceVariant,
            )),
      );
    }
    // name & size are determined together by the folder listing, so use the
    // count of listing-checked files as the shared denominator (item 1: size
    // must never show a smaller denominator than name). Immich fills in async,
    // so it keeps a "known" denominator that hides the chip until resolved.
    final checked = files.where((f) => f.verification != null).toList();
    final n = checked.length;
    final nameYes =
        checked.where((f) => f.verification!.filenamePresent == VerifyState.yes).length;
    final sizeYes =
        checked.where((f) => f.verification!.sizeMatches == VerifyState.yes).length;
    final partial =
        files.where((f) => f.verification?.partialExists == VerifyState.yes).length;
    final immichApplicable =
        files.where((f) => f.verification?.immichApplicable ?? false).toList();

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 10,
        runSpacing: 2,
        children: [
          if (n > 0) _countChip(context, 'name', nameYes, n),
          if (n > 0) _countChip(context, 'size', sizeYes, n),
          if (partial > 0)
            _rawChip(context, 'partial $partial/${files.length}',
                context.colorScheme.error, Icons.error_outline),
          _axisChip(context, 'Immich', immichApplicable, (v) => v.immich),
        ].whereType<Widget>().toList(),
      ),
    );
  }

  Widget _countChip(BuildContext context, String label, int yes, int total) {
    final full = yes == total;
    final none = yes == 0;
    final color = full
        ? Colors.green.shade600
        : (none ? context.colorScheme.error : Colors.orange.shade700);
    final icon = full ? Icons.check_circle : (none ? Icons.cancel : Icons.adjust);
    return _rawChip(context, '$label $yes/$total', color, icon);
  }

  /// Rolls up one axis over [pool], counting only files whose state is KNOWN
  /// (verification present and not `unknown`). Returns null when nothing is
  /// known yet, so the chip is omitted rather than showing a misleading 0/N.
  Widget? _axisChip(
    BuildContext context,
    String label,
    List<UploadFile> pool,
    VerifyState Function(ServerFileVerification v) get,
  ) {
    final known = pool
        .where((f) => f.verification != null && get(f.verification!) != VerifyState.unknown)
        .toList();
    if (known.isEmpty) return null;
    final yes = known.where((f) => get(f.verification!) == VerifyState.yes).length;
    final total = known.length;
    final full = yes == total;
    final none = yes == 0;
    // none here means every KNOWN file is genuinely "no" → error, not grey.
    final color = full
        ? Colors.green.shade600
        : (none ? context.colorScheme.error : Colors.orange.shade700);
    final icon = full
        ? Icons.check_circle
        : (none ? Icons.cancel : Icons.adjust);
    return _rawChip(context, '$label $yes/$total', color, icon);
  }

  Widget _rawChip(BuildContext context, String label, Color color, IconData icon) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Text(label, style: context.textTheme.labelSmall?.copyWith(color: color)),
        ],
      );
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
        // Live server state (Issue 3): name/size from copyparty, NOT a stored
        // receipt. Hash is honestly shown as unchecked until upload/verify.
        if (file.verification != null)
          Padding(
            padding: const EdgeInsets.only(left: 72, bottom: 6),
            child: _LiveChips(v: file.verification!),
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

/// Compact live name/size/partial chips + honest "hash not checked" for the
/// import picker (Issue 3/4). Mirrors the cleanup-page evidence model.
class _LiveChips extends StatelessWidget {
  final ServerFileVerification v;
  const _LiveChips({required this.v});

  Widget _chip(BuildContext context, IconData icon, Color color, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Text(label, style: context.textTheme.labelSmall?.copyWith(color: color)),
        ],
      );

  Widget _state(BuildContext context, String label, VerifyState s) {
    final (icon, color) = switch (s) {
      VerifyState.yes => (Icons.check_circle, Colors.green.shade600),
      VerifyState.no => (Icons.cancel, context.colorScheme.error),
      VerifyState.unknown => (Icons.help_outline, context.colorScheme.onSurfaceVariant),
    };
    return _chip(context, icon, color, label);
  }

  @override
  Widget build(BuildContext context) {
    final grey = context.colorScheme.onSurfaceVariant;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _state(context, 'name', v.filenamePresent),
        _state(context, 'size', v.sizeMatches),
        if (v.partialExists == VerifyState.yes)
          _chip(context, Icons.cancel, context.colorScheme.error, 'partial exists'),
        _chip(context, Icons.help_outline, grey, 'hash not checked'),
        if (v.immichApplicable)
          switch (v.immich) {
            VerifyState.yes =>
              _chip(context, Icons.photo_library_rounded, Colors.green.shade600, 'Immich ✓'),
            VerifyState.no =>
              _chip(context, Icons.image_not_supported_outlined, context.colorScheme.error,
                  'Immich missing'),
            VerifyState.unknown => _chip(context, Icons.hourglass_empty, grey, 'Immich…'),
          },
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

/// The decoded server folder from an upload folder URL (Q1), or null if absent.
String? _folderDisplay(String? folderUrl) {
  if (folderUrl == null) return null;
  try {
    final segs = Uri.parse(folderUrl).pathSegments.where((s) => s.isNotEmpty);
    return '/${segs.join('/')}';
  } catch (_) {
    return null;
  }
}

/// Q1: shows where the selected files will be uploaded, before starting.
class _DestinationBanner extends ConsumerWidget {
  const _DestinationBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cp = ref.watch(appConfigProvider.select((c) => c.copyparty));
    final host = cp.hostUrl.replaceAll(RegExp(r'/+$'), '');
    final path = '/${cp.uploadPath.replaceAll(RegExp(r'^/+|/+$'), '')}';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.folder_outlined, size: 18, color: context.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Uploading to', style: context.textTheme.labelSmall),
                Text(
                  '$host$path',
                  style: context.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (cp.recreateFolderStructure)
                  Text(
                    '+ recreating folder structure',
                    style: context.textTheme.labelSmall
                        ?.copyWith(color: context.colorScheme.primary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UploadProgressStep extends ConsumerWidget {
  final ImportSessionState session;
  final VoidCallback onCancel;
  final VoidCallback onAddFolders;
  const _UploadProgressStep(this.session,
      {required this.onCancel, required this.onAddFolders});

  Future<void> _confirmCancel(BuildContext context) async {
    final stop = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop uploading?'),
        content: const Text(
          'This stops the current upload. Files already uploaded are kept on '
          'the server; the rest can be resumed later from where they left off.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep uploading')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (stop == true) onCancel();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only show the files the user actually chose to upload this run — not the
    // whole card. (selectedPaths is null only for legacy "upload everything".)
    final selected = session.selectedPaths;
    bool keep(UploadFile f) => selected == null || selected.contains(f.localPath);

    // Show groups in the ORDER they upload, so the first group is at the top
    // (not scan order, which looks random once "upload smallest first" reorders
    // the actual queue). Smallest-first → sort by group size; otherwise keep
    // scan order (= upload order for the unsorted case).
    final sortSmallest =
        ref.watch(appConfigProvider.select((c) => c.copyparty.sortSmallestFirst));
    final visibleSets =
        session.uploadSets.where((s) => s.files.any(keep)).toList();
    if (sortSmallest) {
      visibleSets.sort((a, b) => a.totalBytes.compareTo(b.totalBytes));
    }
    final allFiles = session.uploadSets.expand((s) => s.files).where(keep).toList();
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
            itemCount: visibleSets.length,
            itemBuilder: (ctx, i) =>
                _ProgressSetSection(set: visibleSets[i], selectedPaths: selected),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                // Item 2: add more folders to the live queue while uploading.
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onAddFolders,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Add folders'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _confirmCancel(context),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Stop'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      foregroundColor: context.colorScheme.error,
                      side: BorderSide(
                        color: context.colorScheme.error.withValues(alpha: 0.5),
                      ),
                    ),
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
  final Set<String>? selectedPaths;
  const _ProgressSetSection({required this.set, this.selectedPaths});

  @override
  Widget build(BuildContext context) {
    final files = selectedPaths == null
        ? set.files
        : set.files.where((f) => selectedPaths!.contains(f.localPath)).toList();
    final setBytes = files.fold<int>(0, (s, f) => s + f.sizeBytes);
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
                formatHumanReadableBytes(setBytes, 1),
                style: context.textTheme.labelSmall?.copyWith(
                  color: context.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
        ...files.map((f) => Padding(
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
  String _speed = '-- MiB/s';
  String _eta = '--:--';
  UploadFileStatus? _prevStatus;
  DateTime? _transferStart; // first network-transfer tick (excludes hashing)
  Duration? _finalElapsed; // frozen on completion
  String? _finalAvg; // frozen average speed on completion

  // Copyparty chunk upload OR Immich upload — the network-transfer phases.
  static bool _isTransfer(UploadFileStatus? s) =>
      s == UploadFileStatus.uploading || s == UploadFileStatus.immichUploading;

  @override
  void didUpdateWidget(_ProgressFileCard old) {
    super.didUpdateWidget(old);
    final f = widget.file;
    final s = f.status;
    final transferring = _isTransfer(s);

    // Reset the live speed meter at every phase boundary (hashing→copyparty,
    // copyparty→immich) because uploadedBytes restarts — otherwise the byte
    // counter going backwards produces a bogus reading. Hashing is never fed,
    // so the speed reflects network transfer only (item 2).
    if (transferring && s != _prevStatus) {
      _speedCalc.reset();
    }
    if (transferring) {
      _transferStart ??= DateTime.now();
      _speedCalc.update(f.uploadedBytes, f.sizeBytes);
      _speed = _speedCalc.speedAsString;
      _eta = _speedCalc.timeRemainingAsString;
    }

    // Freeze the elapsed transfer time + average once the file is fully done
    // (item 3). Files already on the server never transferred, so skip them.
    final done = s == UploadFileStatus.receiptWritten ||
        (s == UploadFileStatus.confirmed && !f.needsImmich);
    if (done && _finalElapsed == null && _transferStart != null && !f.alreadyOnServer) {
      _finalElapsed = DateTime.now().difference(_transferStart!);
      final secs = _finalElapsed!.inMilliseconds / 1000.0;
      _finalAvg = _formatSpeed(secs > 0 ? f.sizeBytes / secs : 0);
    }
    _prevStatus = s;
  }

  /// "45s" under a minute, "m:ss" from a minute up.
  static String _formatDuration(Duration d) {
    final total = d.inSeconds;
    if (total < 60) return '${total}s';
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  static String _formatSpeed(double bytesPerSec) {
    final mib = bytesPerSec / (1024 * 1024);
    return mib >= 1 ? '${mib.toStringAsFixed(1)} MiB/s' : '${(mib * 1024).round()} KiB/s';
  }

  /// "22.3 / 27.9 MiB" (unit shown once when both share it), else "980 KiB / 27.9 MiB".
  static String _pairBytes(int done, int total) {
    final totalStr = formatHumanReadableBytes(total, 1);
    final doneStr = formatHumanReadableBytes(done, 1);
    final totalUnit = totalStr.split(' ').last;
    final doneParts = doneStr.split(' ');
    if (doneParts.length == 2 && doneParts.last == totalUnit) {
      return '${doneParts.first} / $totalStr';
    }
    return '$doneStr / $totalStr';
  }

  /// A small pill showing which backend the bytes are currently going to
  /// (Copyparty vs Immich), so a "both" file makes its two phases obvious.
  Widget _phaseChip(BuildContext context, UploadFile file) {
    final (String label, IconData icon, Color color) = switch (file.status) {
      UploadFileStatus.hashing =>
        ('Hashing', Icons.tag_rounded, context.colorScheme.onSurfaceVariant),
      UploadFileStatus.handshaking || UploadFileStatus.uploading || UploadFileStatus.confirmed =>
        ('Copyparty', Icons.sd_card_rounded, context.colorScheme.primary),
      UploadFileStatus.immichUploading =>
        ('Immich', Icons.cloud_upload_rounded, context.colorScheme.tertiary),
      _ => ('', Icons.circle, context.colorScheme.primary),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: const BorderRadius.all(Radius.circular(10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: context.textTheme.labelSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final isDone = file.status == UploadFileStatus.receiptWritten ||
        (file.status == UploadFileStatus.confirmed && !file.needsImmich);
    final isFailed = file.status == UploadFileStatus.failed;
    final isActive = !isDone && !isFailed;
    // Hashing is a LOCAL checksum pass, not a network transfer — don't show
    // "transferred / MiB/s" for it (item 1).
    final isHashing = file.status == UploadFileStatus.hashing;

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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          file.filename,
                          style: context.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isActive) ...[
                        const SizedBox(width: 8),
                        _phaseChip(context, file),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isFailed
                        ? file.errorMessage ?? 'Upload failed'
                        : isDone
                            ? (file.alreadyOnServer
                                ? '${formatHumanReadableBytes(file.sizeBytes, 1)} · already on server (hash verified)'
                                : _finalElapsed != null
                                    // total · elapsed · avg speed (item 3)
                                    ? '${formatHumanReadableBytes(file.sizeBytes, 1)} · '
                                      '${_formatDuration(_finalElapsed!)} · avg $_finalAvg'
                                    : '${formatHumanReadableBytes(file.sizeBytes, 1)} · Done')
                            : isHashing
                                ? '${formatHumanReadableBytes(file.sizeBytes, 1)} · computing checksum…'
                                // transferred / total · speed (item 1)
                                : '${_pairBytes(file.uploadedBytes, file.sizeBytes)} · $_speed',
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

    // Only files that were actually part of THIS upload count toward the
    // success/error tally. Files left as `pending` were skipped (unselected)
    // and must not turn a clean run into "Completed with errors". (Issue 1)
    final attempted =
        allFiles.where((f) => f.status != UploadFileStatus.pending).toList();
    final cpSucceeded = attempted.where((f) => f.copypartyConfirmed).length;
    final cpNeeded = attempted.where((f) => f.needsCopyparty).length;
    final imSucceeded = attempted.where((f) => f.immichConfirmed).length;
    final imNeeded = attempted.where((f) => f.needsImmich).length;
    final failed =
        attempted.where((f) => f.status == UploadFileStatus.failed).length;
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
        // Per-group file list — only the files the user actually selected for
        // THIS run, not every scanned file. (item 2)
        Expanded(
          child: Builder(builder: (ctx) {
            final selected = session.selectedPaths;
            bool keep(UploadFile f) =>
                selected == null || selected.contains(f.localPath);
            final visibleSets =
                session.uploadSets.where((s) => s.files.any(keep)).toList();
            return ListView.builder(
              itemCount: visibleSets.length,
              itemBuilder: (ctx, i) {
                final set = visibleSets[i];
                return _CompletionSetSection(
                  set: set,
                  rootPath: session.directoryPath,
                  selectedPaths: selected,
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
            );
          }),
        ),
        // Footer
        const Divider(height: 1),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (failed > 0) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: () =>
                          ref.read(importSessionProvider.notifier).retryFailed(),
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(
                        'Retry $failed failed file${failed == 1 ? '' : 's'}',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
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
                if (ref.watch(
                    appConfigProvider.select((c) => c.copyparty.debugMode))) ...[
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _shareDiagnosticLog(context, ref),
                      icon: const Icon(Icons.bug_report_outlined),
                      label: const Text('Share diagnostic log'),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
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
    // Status-driven (Issue 5) with a LIVE re-check right before deleting — we
    // never trust the upload-time flag alone. A file is safe only if it is
    // STILL on the server now with a freshly RE-VALIDATED content hash (the
    // same bar as the cleanup page — not the stale upload-time flag, and not
    // name+size alone), and Immich is satisfied where it applies. The re-check
    // runs against the file's ACTUAL upload folder (mirrored sub-path when FB9
    // "Recreate folder structure" was used), not the flat base path. If the
    // server is unreachable we BLOCK deletion rather than offer a "delete
    // anyway" that loses the only local copy while offline. (Review C1/C2/BLOCKER1)
    final config = ref.read(appConfigProvider).copyparty;
    final uploader = ref.read(copypartyUploaderProvider);
    String password = '';
    try {
      password = await ref.read(copypartyPasswordProvider.future);
    } catch (_) {}
    final cleanPath = config.uploadPath.replaceAll(RegExp(r'^/+|/+$'), '');
    final base = config.hostUrl.replaceAll(RegExp(r'/+$'), '');

    // Visible progress for the sequential re-verify loop (MEDIUM 5) — on a
    // metered/slow link this is N round-trips + a re-hash each; never freeze
    // the UI silently.
    final progress = ValueNotifier<int>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (ctx, done, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text('Re-verifying $done / ${files.length}…')),
            ],
          ),
        ),
      ),
    );

    final now = DateTime.now();
    final unsafe = <UploadFile>[];
    bool offline = false;
    for (final f in files) {
      // The folder the file was actually uploaded to (mirrored sub-path under
      // FB9), falling back to the flat base path for legacy uploads.
      final folderUrl = f.uploadFolderUrl ?? '$base/$cleanPath';
      final fileUrl = '$folderUrl/${f.filename}';
      try {
        // Cheap presence first; its failure is the clean "server unreachable"
        // signal (the folder listing itself failed).
        final presence = await uploader.verifyPresence(
          fileUrl: fileUrl,
          filename: f.filename,
          expectedSize: f.sizeBytes,
          password: password,
        );
        if (presence.error != null) {
          offline = true;
          unsafe.add(f);
          progress.value++;
          continue;
        }
        // Reachable → re-validate the content hash (the strong proof).
        final v = await uploader.verifyHash(
          fileUrl: fileUrl,
          localPath: f.localPath,
          password: password,
          base: presence,
          now: now,
        );
        final liveSafe =
            v.copypartyVerifiedAt(now) && (!f.needsImmich || f.immichConfirmed);
        if (!liveSafe) unsafe.add(f);
      } catch (_) {
        offline = true;
        unsafe.add(f);
      }
      progress.value++;
    }
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();
    if (!context.mounted) return;

    final bool? confirm;
    if (offline) {
      // Can't prove the server has the files → never offer "delete anyway".
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Can't reach copyparty"),
          content: const Text(
            'The server could not be reached, so these files cannot be confirmed '
            'as safely stored. Deletion is blocked — try again when online.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
      return;
    } else if (unsafe.isEmpty) {
      confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Delete ${files.length} source '
              'file${files.length == 1 ? '' : 's'}?'),
          content: const Text(
            'All selected files are confirmed on copyparty (and in Immich where '
            'applicable). This frees space on the memory card and cannot be undone.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Delete all ${files.length}'),
            ),
          ],
        ),
      );
    } else {
      confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Some files not confirmed'),
          content: Text(
            '${unsafe.length} of ${files.length} selected '
            'file${files.length == 1 ? '' : 's'} could not be confirmed as safely '
            'stored. Deleting them risks data loss. Delete anyway?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: ctx.colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete anyway'),
            ),
          ],
        ),
      );
    }

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
  final Set<String>? selectedPaths;
  final Set<String> checkedForDeletion;
  final void Function(String, bool) onToggle;

  const _CompletionSetSection({
    required this.set,
    required this.rootPath,
    required this.selectedPaths,
    required this.checkedForDeletion,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final relPath = _relPathUtil(rootPath, set.directoryPath);
    final files = selectedPaths == null
        ? set.files
        : set.files.where((f) => selectedPaths!.contains(f.localPath)).toList();
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
        ...files.map(
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
              : Builder(builder: (_) {
                  final immichGood = !file.needsImmich || imOk;
                  final good = !failed && cpOk && immichGood;
                  final text = file.alreadyOnServer
                      ? 'already on server · hash verified'
                      : failed
                          ? 'not confirmed'
                          : cpOk
                              ? (file.needsImmich
                                  ? (imOk
                                      ? 'copyparty ✓ · Immich ✓'
                                      : 'copyparty ✓ · Immich missing')
                                  : 'copyparty ✓ (hash verified)')
                              : 'not confirmed';
                  final folder = _folderDisplay(file.uploadFolderUrl);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text,
                        style: context.textTheme.bodySmall?.copyWith(
                          color: good ? Colors.green : context.colorScheme.error,
                        ),
                      ),
                      if (folder != null)
                        Row(
                          children: [
                            Icon(Icons.folder_outlined,
                                size: 12,
                                color: context.colorScheme.onSurface
                                    .withValues(alpha: 0.5)),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                folder,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.textTheme.labelSmall?.copyWith(
                                  color: context.colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  );
                }),
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

/// Relative folder shown in the picker/completion — INCLUDES the picked root
/// folder's own name so it matches where the file lands on the server under
/// FB9 (e.g. root "australia" + subfolder "sydney bridge" → "australia/sydney
/// bridge"). (item 4)
String _relPathUtil(String? root, String? dir) {
  if (dir == null) return '';
  if (root == null) return dir.split('/').last;
  final rootName = root.split('/').where((s) => s.isNotEmpty).isEmpty
      ? ''
      : root.split('/').where((s) => s.isNotEmpty).last;
  if (dir == root) return rootName;
  if (dir.startsWith('$root/')) {
    final rel = dir.substring(root.length + 1);
    return rootName.isEmpty ? rel : '$rootName/$rel';
  }
  return dir.split('/').last;
}
