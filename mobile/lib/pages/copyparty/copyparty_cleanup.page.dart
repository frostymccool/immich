import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/pages/copyparty/copyparty_import.page.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/copyparty/copyparty.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/services/copyparty/copyparty_file_pairer.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shows uploaded files still present on device so the user can delete them.
///
/// Trust is NEVER assumed from a stored "uploaded" flag — every file is checked
/// live against the server: name present · size matches · no lingering partial
/// · content hash validated · present in Immich (by checksum). A file is only
/// safe to delete once it is hash-verified on copyparty AND Immich-ok.
class CopypartyCleanupPage extends ConsumerStatefulWidget {
  const CopypartyCleanupPage({super.key});

  @override
  ConsumerState<CopypartyCleanupPage> createState() => _CopypartyCleanupPageState();
}

/// Immich applies to a file if it was confirmed in Immich OR it's a media type
/// Immich would ingest (intended destination). Errs toward applicable so an
/// Immich-destined file is never deleted on copyparty-only proof.
bool _immichApplies(CopypartyReceipt r) =>
    r.immichAssetId != null || CopypartyFilePairer.isNativeImmichFilename(r.filename);

/// The decoded server FOLDER a receipt was uploaded to (its URL minus the
/// filename) — includes any FB9 mirrored sub-path. (Q1)
String _folderOf(CopypartyReceipt r) {
  try {
    final uri = Uri.parse(r.copypartyUrl);
    final segs = List<String>.from(uri.pathSegments)..removeWhere((s) => s.isEmpty);
    if (segs.isNotEmpty) {
      segs.removeLast(); // drop the filename
    }
    return '/${segs.join('/')}';
  } catch (_) {
    return '';
  }
}

/// A group of receipts that belong together (Q2): same destination folder and
/// same normalised stem — mirrors how the import picker groups a clip's files.
class _CleanupGroup {
  final String key;
  final String folder;
  final List<CopypartyReceipt> receipts;
  _CleanupGroup({required this.key, required this.folder, required this.receipts});

  /// Representative label — the shortest filename in the set reads best as the
  /// clip name (companions add suffixes/extensions).
  String get title => receipts.map((r) => r.filename).reduce((a, b) => a.length <= b.length ? a : b);

  int get totalBytes => receipts.fold(0, (s, r) => s + r.sizeBytes);
}

class _CopypartyCleanupPageState extends ConsumerState<CopypartyCleanupPage> {
  List<CopypartyReceipt> _existing = [];
  Set<int> _selected = {};
  Map<int, ServerFileVerification> _verify = {};
  final Set<int> _verifying = {};
  final Set<int> _uploading = {};
  final Set<int> _deleted = {};
  final Map<int, double> _progress = {}; // 0..1 during verify/upload (FB2/FB8)
  final Set<String> _collapsed = {}; // group keys currently collapsed (item 7)
  String _password = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final receipts = await ref.read(copypartyReceiptRepositoryProvider).getUndeleted();
    final existing = <CopypartyReceipt>[];
    for (final r in receipts) {
      if (await File(r.localPath).exists()) {
        existing.add(r);
      }
    }
    final password = await ref.read(copypartyPasswordProvider.future);

    if (mounted) {
      setState(() {
        _existing = existing;
        _selected = {}; // nothing pre-selected — must verify first
        _verify = {for (final r in existing) r.id!: ServerFileVerification(immichApplicable: _immichApplies(r))};
        _password = password;
        _loading = false;
      });
    }

    // Sequential (not concurrent) so the two passes don't race on _verify[id].
    await _runPresenceChecks(existing);
    await _checkImmichStatuses(existing);
  }

  /// Merge a partial update into the per-file verification (preserves the
  /// fields the update doesn't touch).
  void _mergeVerify(int id, ServerFileVerification Function(ServerFileVerification) f) {
    if (!mounted) {
      return;
    }
    setState(() {
      _verify[id] = f(_verify[id] ?? const ServerFileVerification());
    });
  }

  /// Prefer an existing staged (phone-cached) copy over the ORIGINAL card path
  /// for any re-hash — it's byte-identical to what was actually uploaded, so
  /// this is strictly equivalent, never weaker, while being faster and not
  /// requiring the card to still be inserted (the whole point of staging).
  Future<String> _effectiveLocalPath(String sourcePath) async {
    final staged = await ref.read(copypartyStagingProvider).findValidStaged(sourcePath);
    return staged?.path ?? sourcePath;
  }

  /// Cheap on-load check: a folder listing per file → presence, size, partial.
  Future<void> _runPresenceChecks(List<CopypartyReceipt> receipts) async {
    final uploader = ref.read(copypartyUploaderProvider);
    for (final r in receipts) {
      final v = await uploader.verifyPresence(
        fileUrl: r.copypartyUrl,
        filename: r.filename,
        expectedSize: r.sizeBytes,
        password: _password,
      );
      _mergeVerify(
        r.id!,
        (cur) => cur.copyWith(
          filenamePresent: v.filenamePresent,
          sizeMatches: v.sizeMatches,
          partialExists: v.partialExists,
          error: v.error,
        ),
      );
    }
  }

  /// Immich presence by CHECKSUM (decision B). CP-only files are n/a.
  Future<void> _checkImmichStatuses(List<CopypartyReceipt> receipts) async {
    final api = ref.read(apiServiceProvider).assetsApi;
    for (final r in receipts) {
      if (!_immichApplies(r)) {
        _mergeVerify(r.id!, (cur) => cur.copyWith(immichApplicable: false, error: cur.error));
        continue;
      }
      VerifyState immich;
      try {
        final assetId = await immichAssetIdByChecksum(api, await _effectiveLocalPath(r.localPath));
        immich = assetId != null ? VerifyState.yes : VerifyState.no;
      } catch (_) {
        immich = VerifyState.unknown;
      }
      _mergeVerify(r.id!, (cur) => cur.copyWith(immich: immich, immichApplicable: true));
    }
  }

  /// Deep verify for one file: re-hash + handshake (copyparty) and re-check
  /// Immich by checksum. Selection is user-driven (FB10) — this never changes
  /// the ticked set; it only updates the verification evidence.
  Future<void> _verifyFile(CopypartyReceipt r) async {
    if (_verifying.contains(r.id)) {
      return;
    }
    setState(() {
      _verifying.add(r.id!);
      _progress[r.id!] = 0;
    });
    final uploader = ref.read(copypartyUploaderProvider);
    final api = ref.read(apiServiceProvider).assetsApi;
    try {
      final effectivePath = await _effectiveLocalPath(r.localPath);
      final cp = await uploader.verifyHash(
        fileUrl: r.copypartyUrl,
        localPath: effectivePath,
        password: _password,
        base: _verify[r.id!] ?? const ServerFileVerification(),
        onHashProgress: (done, total) {
          if (total > 0 && mounted) {
            setState(() => _progress[r.id!] = done / total);
          }
        },
      );
      VerifyState immich = VerifyState.unknown;
      bool applicable = _immichApplies(r);
      if (applicable) {
        try {
          immich = (await immichAssetIdByChecksum(api, effectivePath)) != null ? VerifyState.yes : VerifyState.no;
        } catch (_) {
          immich = VerifyState.unknown;
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _verify[r.id!] = cp.copyWith(immich: immich, immichApplicable: applicable);
        _verifying.remove(r.id);
        _progress.remove(r.id);
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _verifying.remove(r.id);
        _progress.remove(r.id);
      });
    }
  }

  /// Verify the currently-ticked files (FB10). Selection is user-driven.
  Future<void> _verifySelected() async {
    for (final r in _existing) {
      if (!_selected.contains(r.id) || _deleted.contains(r.id)) {
        continue;
      }
      if (!mounted) {
        return;
      }
      await _verifyFile(r);
    }
  }

  void _toggleSelectAll(bool selectAll) {
    setState(() {
      if (selectAll) {
        _selected = _existing.where((r) => !_deleted.contains(r.id)).map((r) => r.id!).toSet();
      } else {
        _selected = {};
      }
    });
  }

  /// Groups receipts by (folder, normalised stem) preserving first-seen order,
  /// mirroring the import picker's set grouping. (Q2)
  List<_CleanupGroup> _buildGroups() {
    final config = ref.read(appConfigProvider).copyparty;
    final pairer = CopypartyFilePairer(triggerExtensions: config.triggerExtensions);
    final groups = <String, _CleanupGroup>{};
    final order = <String>[];
    for (final r in _existing) {
      final folder = _folderOf(r);
      final key = '$folder :: ${pairer.normalise(r.filename)}';
      final g = groups[key];
      if (g == null) {
        groups[key] = _CleanupGroup(key: key, folder: folder, receipts: [r]);
        order.add(key);
      } else {
        g.receipts.add(r);
      }
    }
    return [for (final k in order) groups[k]!];
  }

  /// Select every file that is currently SAFE to delete (hash-verified on
  /// copyparty and Immich-ok). Makes it a one-tap job to tick the deletable
  /// ones. (item 9)
  void _selectAllVerified() {
    final now = DateTime.now();
    setState(() {
      _selected = _existing
          .where((r) => !_deleted.contains(r.id) && (_verify[r.id]?.safeToDeleteAt(now) ?? false))
          .map((r) => r.id!)
          .toSet();
    });
  }

  /// Remove a stale/unwanted receipt from the cleanup list WITHOUT touching the
  /// local file — marks it sourceDeleted so it stops showing. (item 6)
  Future<void> _removeFromList(CopypartyReceipt r) async {
    if (r.id == null) {
      return;
    }
    await ref.read(copypartyReceiptRepositoryProvider).markSourceDeleted(r.id!);
    if (!mounted) {
      return;
    }
    setState(() {
      _existing = _existing.where((e) => e.id != r.id).toList();
      _selected.remove(r.id);
      _verify.remove(r.id);
    });
    ref.invalidate(pendingCleanupProvider);
  }

  /// Bulk "Remove from list" for the current selection (batch3 item 19) — same
  /// semantics as the per-file action: stops tracking, deletes nothing.
  Future<void> _removeSelected() async {
    final targets = _existing.where((r) => _selected.contains(r.id) && !_deleted.contains(r.id)).toList();
    if (targets.isEmpty) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${targets.length} from list?'),
        content: const Text(
          'This only stops tracking these files for cleanup. '
          'The local files and the server copies are NOT deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    for (final r in targets) {
      await _removeFromList(r);
    }
  }

  void _setAllCollapsed(bool collapsed) {
    setState(() {
      _collapsed.clear();
      if (collapsed) {
        for (final g in _buildGroups()) {
          if (g.receipts.length > 1) {
            _collapsed.add(g.key);
          }
        }
      }
    });
  }

  /// Tri-state for a group's select box: true (all), false (none), null (some).
  bool? _groupValue(_CleanupGroup g) {
    final ids = g.receipts.where((r) => !_deleted.contains(r.id)).map((r) => r.id!).toList();
    if (ids.isEmpty) {
      return false;
    }
    final selected = ids.where(_selected.contains).length;
    if (selected == 0) {
      return false;
    }
    if (selected == ids.length) {
      return true;
    }
    return null;
  }

  void _toggleGroup(_CleanupGroup g, bool select) {
    setState(() {
      for (final r in g.receipts) {
        if (_deleted.contains(r.id)) {
          continue;
        }
        if (select) {
          _selected.add(r.id!);
        } else {
          _selected.remove(r.id);
        }
      }
    });
  }

  /// Verify just the (non-deleted) files in one group. (Q2 per-group verify)
  Future<void> _verifyGroup(_CleanupGroup g) async {
    for (final r in g.receipts) {
      if (_deleted.contains(r.id)) {
        continue;
      }
      if (!mounted) {
        return;
      }
      await _verifyFile(r);
    }
  }

  /// Recovery (Issue 8, reworked batch3 item 18): re-upload now goes through
  /// the MAIN import queue, so it shows on the active-uploads pages with the
  /// full progress card. The file's ORIGINAL server folder is preserved via
  /// uploadPathOverride (review L1), and the fresh receipt supersedes this one.
  Future<void> _uploadNow(CopypartyReceipt r) async {
    await ref.read(importSessionProvider.notifier).queueReceiptUploads([r]);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Queued ${r.filename} for upload'),
        action: SnackBarAction(
          label: 'View',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CopypartyImportPage())),
        ),
      ),
    );
  }

  Future<void> _deleteSelected() async {
    final now = DateTime.now();
    // Exclude already-deleted rows defensively — they can't be deleted twice
    // and must not inflate counts. (Review MEDIUM 7)
    final toDelete = _existing.where((r) => _selected.contains(r.id) && !_deleted.contains(r.id)).toList();
    if (toDelete.isEmpty) {
      return;
    }

    final unsafe = toDelete.where((r) => !(_verify[r.id]?.safeToDeleteAt(now) ?? false)).toList();

    final bool proceed;
    if (unsafe.isEmpty) {
      // All-clear: every selected file is hash-verified on copyparty + Immich-ok.
      final immichBound = toDelete.where((r) => _verify[r.id]?.immichApplicable ?? false).length;
      proceed =
          (await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(
                'Delete ${toDelete.length} source '
                'file${toDelete.length == 1 ? '' : 's'}?',
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AllClearLine('All ${toDelete.length} are hash-verified on copyparty.'),
                  if (immichBound > 0)
                    _AllClearLine(
                      'All $immichBound Immich-bound '
                      'file${immichBound == 1 ? '' : 's'} present in Immich.',
                    ),
                  const SizedBox(height: 6),
                  Text(
                    'This cannot be undone.',
                    style: TextStyle(color: ctx.colorScheme.onSurface.withValues(alpha: 0.6)),
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Delete all ${toDelete.length}')),
              ],
            ),
          )) ??
          false;
    } else {
      // Mixed: some selected files are not safe. Warn explicitly.
      proceed =
          (await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Some files not verified'),
              content: Text(
                '${unsafe.length} of ${toDelete.length} selected '
                'file${toDelete.length == 1 ? '' : 's'} are NOT fully verified '
                '(missing, wrong size, a partial exists, hash not validated, or '
                'not in Immich). Deleting them risks data loss. Delete anyway?',
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
          )) ??
          false;
    }
    if (proceed != true) {
      return;
    }

    final repo = ref.read(copypartyReceiptRepositoryProvider);
    final deletedIds = <int>[];
    for (final receipt in toDelete) {
      try {
        await File(receipt.localPath).delete();
        await repo.markSourceDeleted(receipt.id!);
        deletedIds.add(receipt.id!);
      } catch (_) {}
    }
    if (mounted) {
      // Keep deleted rows visible, struck-through and unticked (FB7) — don't
      // silently drop them, so the user sees what was removed.
      setState(() {
        _deleted.addAll(deletedIds);
        _selected.removeAll(deletedIds);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deleted ${deletedIds.length} / ${toDelete.length} files')));
      ref.invalidate(pendingCleanupProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final busy = _verifying.isNotEmpty || _uploading.isNotEmpty;
    final selectable = _existing.where((r) => !_deleted.contains(r.id)).map((r) => r.id!).toSet();
    final allSelected = selectable.isNotEmpty && selectable.every(_selected.contains);
    final allSelectedSafe =
        _selected.isNotEmpty &&
        _existing.where((r) => _selected.contains(r.id)).every((r) => _verify[r.id]?.safeToDeleteAt(now) ?? false);
    // batch3 item 15: only offer "Select verified" when something IS verified.
    final anyVerified = _existing.any((r) => !_deleted.contains(r.id) && (_verify[r.id]?.safeToDeleteAt(now) ?? false));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pending Cleanup'),
        centerTitle: false,
        actions: [
          if (!_loading && _existing.isNotEmpty) ...[
            if (anyVerified) TextButton(onPressed: _selectAllVerified, child: const Text('Select verified')),
            TextButton(
              onPressed: (busy || _selected.isEmpty) ? null : _verifySelected,
              child: Text('Verify${_selected.isEmpty ? '' : ' (${_selected.length})'}'),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'selectAll':
                    _toggleSelectAll(!allSelected);
                  case 'expandAll':
                    _setAllCollapsed(false);
                  case 'collapseAll':
                    _setAllCollapsed(true);
                  case 'removeSelected':
                    _removeSelected();
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(value: 'selectAll', child: Text(allSelected ? 'Deselect all' : 'Select all')),
                const PopupMenuItem(value: 'expandAll', child: Text('Expand all')),
                const PopupMenuItem(value: 'collapseAll', child: Text('Collapse all')),
                // batch3 item 19: bulk variant of the per-file "Remove from list".
                if (_selected.isNotEmpty)
                  PopupMenuItem(value: 'removeSelected', child: Text('Remove ${_selected.length} from list')),
              ],
            ),
          ],
        ],
      ),
      // Q4: long-press select + copy for all text on this page (support).
      body: SelectionArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator.adaptive())
            : _existing.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle_outline, size: 64, color: context.primaryColor),
                    const SizedBox(height: 16),
                    const Text('Nothing to clean up'),
                    const SizedBox(height: 8),
                    Text(
                      'All uploaded source files have been deleted from this device.',
                      textAlign: TextAlign.center,
                      style: context.textTheme.bodySmall,
                    ),
                  ],
                ),
              )
            : Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: context.colorScheme.surfaceContainer,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(
                      'Files are only safe to delete once verified on copyparty '
                      '(and present in Immich, if applicable). Select files and '
                      'tap "Verify" to re-hash and confirm each one.',
                      style: context.textTheme.bodySmall?.copyWith(
                        color: context.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _loadExisting,
                      child: Builder(
                        builder: (ctx) {
                          final groups = _buildGroups();
                          return ListView.builder(
                            itemCount: groups.length,
                            itemBuilder: (ctx, i) {
                              final g = groups[i];
                              return _CleanupGroupSection(
                                group: g,
                                groupValue: _groupValue(g),
                                busy: busy,
                                now: now,
                                collapsed: _collapsed.contains(g.key),
                                onToggleCollapse: () => setState(() {
                                  if (!_collapsed.remove(g.key)) {
                                    _collapsed.add(g.key);
                                  }
                                }),
                                verifications: [
                                  for (final r in g.receipts) _verify[r.id] ?? const ServerFileVerification(),
                                ],
                                onGroupToggle: (v) => _toggleGroup(g, v ?? false),
                                onGroupVerify: () => _verifyGroup(g),
                                tiles: [
                                  for (final r in g.receipts)
                                    _CleanupTile(
                                      receipt: r,
                                      isSelected: _selected.contains(r.id),
                                      deleted: _deleted.contains(r.id),
                                      verification: _verify[r.id] ?? const ServerFileVerification(),
                                      verifying: _verifying.contains(r.id),
                                      uploading: _uploading.contains(r.id),
                                      progress: _progress[r.id],
                                      now: now,
                                      onVerify: () => _verifyFile(r),
                                      onUploadNow: () => _uploadNow(r),
                                      onRemove: () => _removeFromList(r),
                                      onChanged: _deleted.contains(r.id)
                                          ? null
                                          : (sel) => setState(() {
                                              if (sel == true) {
                                                _selected.add(r.id!);
                                              } else {
                                                _selected.remove(r.id);
                                              }
                                            }),
                                    ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _selected.isEmpty ? null : _deleteSelected,
                          icon: Icon(allSelectedSafe ? Icons.delete_outline_rounded : Icons.warning_amber_rounded),
                          label: Text(
                            _selected.isEmpty
                                ? 'Select verified files to delete'
                                : 'Delete ${_selected.length} '
                                      'file${_selected.length == 1 ? '' : 's'}'
                                      '${allSelectedSafe ? '' : ' (unverified!)'}',
                          ),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                            // Destructive-red ONLY when the selection contains
                            // unverified files; the all-clear delete uses the
                            // normal primary colour so safe vs unsafe are
                            // visually distinct before the dialog. (M2)
                            backgroundColor: (_selected.isEmpty || allSelectedSafe) ? null : context.colorScheme.error,
                            foregroundColor: (_selected.isEmpty || allSelectedSafe)
                                ? null
                                : context.colorScheme.onError,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _AllClearLine extends StatelessWidget {
  final String text;
  const _AllClearLine(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, size: 15, color: Colors.green),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: const TextStyle(color: Colors.green)),
        ),
      ],
    ),
  );
}

/// A grouped set of cleanup tiles under one header (Q2): folder + representative
/// name, a group select box (tri-state), a rolled-up status summary, and a
/// per-group Verify action. A single-file "group" renders the file directly
/// (no redundant header) with just a slim folder line.
class _CleanupGroupSection extends StatelessWidget {
  final _CleanupGroup group;
  final bool? groupValue;
  final bool busy;
  final DateTime now;
  final bool collapsed;
  final VoidCallback onToggleCollapse;
  final List<ServerFileVerification> verifications;
  final ValueChanged<bool?> onGroupToggle;
  final VoidCallback onGroupVerify;
  final List<Widget> tiles;

  const _CleanupGroupSection({
    required this.group,
    required this.groupValue,
    required this.busy,
    required this.now,
    required this.collapsed,
    required this.onToggleCollapse,
    required this.verifications,
    required this.onGroupToggle,
    required this.onGroupVerify,
    required this.tiles,
  });

  Widget _folderLine(BuildContext context) => Row(
    children: [
      Icon(Icons.folder_outlined, size: 13, color: context.colorScheme.onSurface.withValues(alpha: 0.5)),
      const SizedBox(width: 4),
      Expanded(
        child: Text(
          group.folder,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.textTheme.labelSmall?.copyWith(color: context.colorScheme.onSurface.withValues(alpha: 0.6)),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    // Item 1: a single-file group is just the file — no separate header (which
    // duplicated the checkbox/Verify). Show a slim folder line + the tile.
    if (group.receipts.length == 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: _folderLine(context)),
          ...tiles,
          const SizedBox(height: 4),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          color: context.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
          child: Row(
            children: [
              Checkbox(value: groupValue, tristate: true, onChanged: (v) => onGroupToggle(v ?? false)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Row(
                      children: [
                        Expanded(child: _folderLine(context)),
                        Text(
                          '  ${group.receipts.length} · ${formatHumanReadableBytes(group.totalBytes, 1)}',
                          style: context.textTheme.labelSmall?.copyWith(
                            color: context.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                    // Item 2: rolled-up status so the group's state is visible
                    // at the top without scanning each file.
                    _summary(context),
                  ],
                ),
              ),
              TextButton(onPressed: busy ? null : onGroupVerify, child: const Text('Verify')),
              // Item 7: fold the group open/closed.
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: onToggleCollapse,
                icon: Icon(collapsed ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded),
              ),
            ],
          ),
        ),
        if (!collapsed) ...tiles,
        const SizedBox(height: 4),
      ],
    );
  }

  /// Rolls up the group's per-file verification into compact chips. Denominators
  /// are per-axis KNOWN counts so an unchecked axis never reads as "absent".
  Widget _summary(BuildContext context) {
    final partial = verifications.where((v) => v.partialExists == VerifyState.yes).length;
    final hashFresh = verifications.where((v) => v.hashFreshAt(now)).length;
    final immichPool = verifications.where((v) => v.immichApplicable).toList();
    final immichYes = immichPool.where((v) => v.immich == VerifyState.yes).length;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 10,
        runSpacing: 2,
        children: [
          // name & size share the SAME denominator (the whole group) — an
          // absent file has no server size, but it still counts as "not size-
          // matched" so size never reads a smaller denominator than name. (item 1)
          _countChip(
            context,
            'name',
            verifications.where((v) => v.filenamePresent == VerifyState.yes).length,
            verifications.length,
          ),
          _countChip(
            context,
            'size',
            verifications.where((v) => v.sizeMatches == VerifyState.yes).length,
            verifications.length,
          ),
          if (partial > 0)
            _rawChip(
              context,
              'partial $partial/${verifications.length}',
              context.colorScheme.error,
              Icons.error_outline,
            ),
          // hash: 0 means "not checked" (grey, fingerprint), not "absent".
          _countChip(
            context,
            'hash',
            hashFresh,
            verifications.length,
            neutralWhenZero: true,
            zeroIcon: Icons.fingerprint,
          ),
          if (immichPool.isNotEmpty) _countChip(context, 'Immich', immichYes, immichPool.length),
        ].whereType<Widget>().toList(),
      ),
    );
  }

  Widget _countChip(
    BuildContext context,
    String label,
    int yes,
    int total, {
    bool neutralWhenZero = false,
    IconData? zeroIcon,
  }) {
    final full = yes == total;
    final none = yes == 0;
    final color = full
        ? Colors.green.shade600
        : (none
              ? (neutralWhenZero ? context.colorScheme.onSurfaceVariant : context.colorScheme.error)
              : Colors.orange.shade700);
    final icon = full ? Icons.check_circle : (none ? (zeroIcon ?? Icons.cancel) : Icons.adjust);
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

class _CleanupTile extends StatelessWidget {
  final CopypartyReceipt receipt;
  final bool isSelected;
  final bool deleted;
  final ServerFileVerification verification;
  final bool verifying;
  final bool uploading;
  final double? progress;
  final DateTime now;
  final VoidCallback onVerify;
  final VoidCallback onUploadNow;
  final VoidCallback onRemove;
  final ValueChanged<bool?>? onChanged;

  const _CleanupTile({
    required this.receipt,
    required this.isSelected,
    required this.deleted,
    required this.verification,
    required this.verifying,
    required this.uploading,
    required this.progress,
    required this.now,
    required this.onVerify,
    required this.onUploadNow,
    required this.onRemove,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final v = verification;
    final safe = v.safeToDeleteAt(now);
    // Verification has been attempted and the copyparty side is NOT good.
    final hashTried = v.hashValidatedAt != null;
    final cpFailed =
        (v.filenamePresent == VerifyState.no ||
        v.sizeMatches == VerifyState.no ||
        v.partialExists == VerifyState.yes ||
        (hashTried && !v.hashFreshAt(now)));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            value: deleted ? false : isSelected,
            onChanged: deleted ? null : onChanged,
            title: Text(
              receipt.filename,
              style: context.textTheme.bodyMedium?.copyWith(
                decoration: deleted ? TextDecoration.lineThrough : null,
                color: deleted ? context.colorScheme.onSurface.withValues(alpha: 0.4) : null,
              ),
            ),
            subtitle: deleted
                ? Text(
                    'Deleted from device',
                    style: context.textTheme.bodySmall?.copyWith(
                      decoration: TextDecoration.lineThrough,
                      color: context.colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${formatHumanReadableBytes(receipt.sizeBytes, 1)} · '
                        'uploaded ${DateFormat.yMd().format(receipt.uploadTimestamp.toLocal())}',
                        style: context.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _StateChip(label: 'name', state: v.filenamePresent),
                          _StateChip(label: 'size', state: v.sizeMatches),
                          // Affirmative wording (Issue 9): show "partial exists" in red
                          // when one is present; "no partial" in green only when none.
                          if (v.partialExists == VerifyState.yes)
                            const _RawChip(label: 'partial exists', state: VerifyState.no)
                          else if (v.partialExists == VerifyState.no)
                            const _RawChip(label: 'no partial', state: VerifyState.yes)
                          else
                            const _RawChip(label: 'partial ?', state: VerifyState.unknown),
                          _HashChip(
                            verifying: verifying,
                            validatedFresh: v.hashFreshAt(now),
                            validatedStale: hashTried && !v.hashFreshAt(now),
                          ),
                          _ImmichChip(verification: v),
                        ],
                      ),
                      if (v.error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            v.error!,
                            style: context.textTheme.labelSmall?.copyWith(color: context.colorScheme.error),
                          ),
                        ),
                      // Progress bar + % while verifying (hashing) or uploading (FB2/FB8).
                      if ((verifying || uploading))
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(value: progress, minHeight: 4),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${uploading ? 'Uploading' : 'Hashing'} '
                                '${progress == null ? '' : '${(progress! * 100).round()}%'}',
                                style: context.textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          // batch3 item 16: a hash Verify is pointless when the file
                          // is known absent (name missing) or a partial exists — the
                          // recovery there is "Upload now", not a verify.
                          if (v.filenamePresent != VerifyState.no && v.partialExists != VerifyState.yes)
                            TextButton.icon(
                              onPressed: (verifying || uploading) ? null : onVerify,
                              icon: verifying
                                  ? const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(strokeWidth: 1.5),
                                    )
                                  : Icon(safe ? Icons.verified_rounded : Icons.fingerprint_rounded, size: 16),
                              label: Text(verifying ? 'Verifying…' : (safe ? 'Verified' : 'Verify')),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                              ),
                            ),
                          // Recovery (Issue 8): offer re-upload when verification failed.
                          if (cpFailed && !verifying)
                            TextButton.icon(
                              onPressed: uploading ? null : onUploadNow,
                              icon: uploading
                                  ? const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(strokeWidth: 1.5),
                                    )
                                  // batch3 item 17: icons match the actual targets —
                                  // copyparty (card) always, plus Immich when this file
                                  // belongs there and isn't confirmed present yet.
                                  : Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.sd_card_rounded, size: 16),
                                        if (_immichApplies(receipt) && v.immich != VerifyState.yes) ...[
                                          const SizedBox(width: 2),
                                          const Icon(Icons.photo_library_rounded, size: 16),
                                        ],
                                      ],
                                    ),
                              label: Text(uploading ? 'Uploading…' : 'Upload now'),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                              ),
                            ),
                          IconButton(
                            icon: const Icon(Icons.open_in_browser_outlined, size: 18),
                            tooltip: 'Open in copyparty',
                            visualDensity: VisualDensity.compact,
                            onPressed: () async {
                              final uri = Uri.tryParse(receipt.copypartyUrl);
                              if (uri != null) {
                                await launchUrl(uri, mode: LaunchMode.externalApplication);
                              }
                            },
                          ),
                          const Spacer(),
                          // Item 6: drop a stale entry from the list (does NOT touch
                          // the local file — just stops tracking it for cleanup).
                          IconButton(
                            icon: const Icon(Icons.playlist_remove_rounded, size: 20),
                            tooltip: 'Remove from list',
                            visualDensity: VisualDensity.compact,
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Remove from list?'),
                                  content: const Text(
                                    'This only stops tracking this file for cleanup. '
                                    'The local file and the server copy are NOT deleted.',
                                  ),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('Remove'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok == true) {
                                onRemove();
                              }
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
            controlAffinity: ListTileControlAffinity.leading,
            isThreeLine: true,
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

/// ✓ / ✗ / ❓ chip whose label colour follows the state directly.
class _RawChip extends StatelessWidget {
  final String label;
  final VerifyState state;
  const _RawChip({required this.label, required this.state});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (state) {
      VerifyState.yes => (Icons.check_circle, Colors.green),
      VerifyState.no => (Icons.cancel, context.colorScheme.error),
      VerifyState.unknown => (Icons.help_outline, context.colorScheme.onSurfaceVariant),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(label, style: context.textTheme.labelSmall?.copyWith(color: color)),
      ],
    );
  }
}

/// Same as _RawChip — kept for the name/size chips.
class _StateChip extends StatelessWidget {
  final String label;
  final VerifyState state;
  const _StateChip({required this.label, required this.state});

  @override
  Widget build(BuildContext context) => _RawChip(label: label, state: state);
}

class _HashChip extends StatelessWidget {
  final bool verifying;
  final bool validatedFresh;
  final bool validatedStale;

  const _HashChip({required this.verifying, required this.validatedFresh, required this.validatedStale});

  @override
  Widget build(BuildContext context) {
    if (verifying) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: context.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 3),
          Text('hash…', style: context.textTheme.labelSmall?.copyWith(color: context.colorScheme.onSurfaceVariant)),
        ],
      );
    }
    final (icon, color, text) = validatedFresh
        ? (Icons.check_circle, Colors.green, 'hash ✓')
        : validatedStale
        ? (Icons.history_rounded, Colors.orange, 'hash stale')
        : (Icons.help_outline, context.colorScheme.onSurfaceVariant, 'hash ?');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(text, style: context.textTheme.labelSmall?.copyWith(color: color)),
      ],
    );
  }
}

class _ImmichChip extends StatelessWidget {
  final ServerFileVerification verification;
  const _ImmichChip({required this.verification});

  @override
  Widget build(BuildContext context) {
    if (!verification.immichApplicable) {
      return const _RawChip(label: 'Immich n/a', state: VerifyState.unknown);
    }
    final (icon, color, text) = switch (verification.immich) {
      VerifyState.yes => (Icons.photo_library_rounded, Colors.green, 'Immich ✓'),
      VerifyState.no => (Icons.image_not_supported_outlined, context.colorScheme.error, 'Immich missing'),
      VerifyState.unknown => (Icons.hourglass_empty, context.colorScheme.onSurfaceVariant, 'Immich…'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(text, style: context.textTheme.labelSmall?.copyWith(color: color)),
      ],
    );
  }
}
