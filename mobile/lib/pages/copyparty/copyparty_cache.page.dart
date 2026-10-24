import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/pages/copyparty/copyparty_import.page.dart';
import 'package:immich_mobile/providers/copyparty/copyparty.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/services/copyparty/copyparty_staging.service.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_mobile/utils/disk_space.dart';
import 'package:intl/intl.dart';

/// Manage the phone staging cache (batch3 item 20): shows every complete cached
/// copy with its size and original source, and offers per-file / bulk delete and
/// "Upload" (queues the file into the live import — bytes come from the cache,
/// so this works even with the card unplugged). Also surfaces any orphaned
/// partial (no completion marker) as delete-only, so the total here always
/// matches the live cache-size indicator shown elsewhere. (cache-consistency fix)
class CopypartyCachePage extends ConsumerStatefulWidget {
  const CopypartyCachePage({super.key});

  @override
  ConsumerState<CopypartyCachePage> createState() => _CopypartyCachePageState();
}

class _CopypartyCachePageState extends ConsumerState<CopypartyCachePage> {
  List<StagedCacheEntry>? _entries;
  final Set<String> _selected = {};
  // Same free-space snapshot the settings slider uses, so the "budget" shown
  // here always matches — see effectiveCacheBudgetMb(). (cache-consistency fix)
  int? _freeBytes;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(
      freeSpaceBytes().then((v) {
        if (mounted) {
          setState(() => _freeBytes = v);
        }
      }),
    );
  }

  Future<void> _load() async {
    final entries = await ref.read(copypartyStagingProvider).listEntries();
    if (mounted) {
      setState(() {
        _entries = entries;
        _selected.removeWhere((p) => !entries.any((e) => e.sourcePath == p));
      });
    }
  }

  Future<void> _delete(List<StagedCacheEntry> targets) async {
    if (targets.isEmpty) {
      return;
    }
    final bytes = targets.fold<int>(0, (s, e) => s + e.sizeBytes);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${targets.length} cached cop${targets.length == 1 ? 'y' : 'ies'}?'),
        content: Text(
          'Frees ${formatHumanReadableBytes(bytes, 1)} of phone storage. Only the '
          'CACHE copies are deleted — the original files on the card and anything '
          'already uploaded are not touched. A file still needed later will simply '
          'be re-copied from the card.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    final staging = ref.read(copypartyStagingProvider);
    for (final e in targets) {
      if (e.complete) {
        await staging.discard(e.sourcePath);
      } else {
        await staging.discardOrphan(e.stagedPath);
      }
    }
    await _load();
  }

  Future<void> _upload(List<StagedCacheEntry> targets) async {
    // Incomplete (orphaned) entries have no marker to resume/upload from —
    // callers should already exclude them, but never queue one by mistake.
    final completeTargets = targets.where((e) => e.complete).toList();
    if (completeTargets.isEmpty) {
      return;
    }
    await ref.read(importSessionProvider.notifier).queueCachedFiles(completeTargets);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Queued ${completeTargets.length} file${completeTargets.length == 1 ? '' : 's'} for upload'),
        action: SnackBarAction(
          label: 'View',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CopypartyImportPage())),
        ),
      ),
    );
    setState(() => _selected.clear());
  }

  String _headerText(List<StagedCacheEntry> entries, int total, int budgetMb) {
    final incomplete = entries.where((e) => !e.complete).length;
    final complete = entries.length - incomplete;
    final countText = incomplete == 0
        ? '$complete cached file${complete == 1 ? '' : 's'}'
        : '$complete cached file${complete == 1 ? '' : 's'}, $incomplete incomplete';
    return '$countText · ${formatHumanReadableBytes(total, 1)} used of ${budgetMb ~/ 1024} GiB budget';
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final total = entries?.fold<int>(0, (s, e) => s + e.sizeBytes) ?? 0;
    final configuredMb = ref.watch(appConfigProvider.select((c) => c.copyparty.cacheSizeMb));
    // The same clamp the settings slider applies to its own display — before
    // this, this page showed the raw configured value unclamped while the
    // slider showed a clamped one, so the two could flatly disagree (e.g.
    // "32 GiB budget" here vs "Max 17 GiB" there) for the exact same setting.
    final budgetMb = effectiveCacheBudgetMb(configuredMb: configuredMb, freeBytes: _freeBytes, usedBytes: total);
    final selectedEntries = entries?.where((e) => _selected.contains(e.sourcePath)).toList() ?? [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Phone cache'),
        centerTitle: false,
        actions: [
          if ((entries ?? []).isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                if (_selected.length == entries!.length) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(entries.map((e) => e.sourcePath));
                }
              }),
              child: Text(_selected.length == (entries?.length ?? 0) ? 'Deselect all' : 'Select all'),
            ),
        ],
      ),
      body: entries == null
          ? const Center(child: CircularProgressIndicator.adaptive())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  color: context.colorScheme.surfaceContainer,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: Text(
                    _headerText(entries, total, budgetMb),
                    style: context.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
                Expanded(
                  child: entries.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.phonelink_erase_rounded,
                                size: 56,
                                color: context.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: 12),
                              const Text('Cache is empty'),
                              const SizedBox(height: 6),
                              Text(
                                'Files copied from the card appear here until their upload completes.',
                                textAlign: TextAlign.center,
                                style: context.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            itemCount: entries.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (ctx, i) {
                              final e = entries[i];
                              return CheckboxListTile(
                                value: _selected.contains(e.sourcePath),
                                onChanged: (v) => setState(() {
                                  if (v == true) {
                                    _selected.add(e.sourcePath);
                                  } else {
                                    _selected.remove(e.sourcePath);
                                  }
                                }),
                                controlAffinity: ListTileControlAffinity.leading,
                                title: Text(e.filename, style: context.textTheme.bodyMedium),
                                isThreeLine: true,
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${formatHumanReadableBytes(e.sizeBytes, 1)} · '
                                      '${e.complete ? 'cached' : 'incomplete, not uploadable —'} '
                                      '${DateFormat.yMd().add_Hm().format(e.modified.toLocal())}',
                                      style: e.complete
                                          ? context.textTheme.bodySmall
                                          : context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error),
                                    ),
                                    if (e.complete)
                                      Text(
                                        e.sourcePath,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.textTheme.labelSmall?.copyWith(
                                          color: context.colorScheme.onSurfaceVariant,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    Row(
                                      children: [
                                        if (e.complete)
                                          TextButton.icon(
                                            onPressed: () => _upload([e]),
                                            icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                                            label: const Text('Upload'),
                                            style: TextButton.styleFrom(
                                              visualDensity: VisualDensity.compact,
                                              padding: const EdgeInsets.symmetric(horizontal: 8),
                                            ),
                                          ),
                                        TextButton.icon(
                                          onPressed: () => _delete([e]),
                                          icon: const Icon(Icons.delete_outline_rounded, size: 16),
                                          label: const Text('Delete'),
                                          style: TextButton.styleFrom(
                                            visualDensity: VisualDensity.compact,
                                            padding: const EdgeInsets.symmetric(horizontal: 8),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                ),
                if (selectedEntries.isNotEmpty)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          if (selectedEntries.any((e) => e.complete))
                            Expanded(
                              child: FilledButton.tonalIcon(
                                onPressed: () => _upload(selectedEntries),
                                icon: const Icon(Icons.cloud_upload_outlined),
                                label: Text('Upload ${selectedEntries.where((e) => e.complete).length}'),
                                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                              ),
                            ),
                          if (selectedEntries.any((e) => e.complete)) const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _delete(selectedEntries),
                              icon: const Icon(Icons.delete_outline_rounded),
                              label: Text('Delete ${selectedEntries.length}'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(48),
                                foregroundColor: context.colorScheme.error,
                                side: BorderSide(color: context.colorScheme.error.withValues(alpha: 0.5)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
