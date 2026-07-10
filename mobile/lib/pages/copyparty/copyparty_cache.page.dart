import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/pages/copyparty/copyparty_import.page.dart';
import 'package:immich_mobile/providers/copyparty/copyparty.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/services/copyparty/copyparty_staging.service.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:intl/intl.dart';

/// Manage the phone staging cache (batch3 item 20): shows every complete cached
/// copy with its size and original source, and offers per-file / bulk delete and
/// "Upload" (queues the file into the live import — bytes come from the cache,
/// so this works even with the card unplugged).
class CopypartyCachePage extends ConsumerStatefulWidget {
  const CopypartyCachePage({super.key});

  @override
  ConsumerState<CopypartyCachePage> createState() => _CopypartyCachePageState();
}

class _CopypartyCachePageState extends ConsumerState<CopypartyCachePage> {
  List<StagedCacheEntry>? _entries;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
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
      await staging.discard(e.sourcePath);
    }
    await _load();
  }

  Future<void> _upload(List<StagedCacheEntry> targets) async {
    if (targets.isEmpty) {
      return;
    }
    await ref.read(importSessionProvider.notifier).queueCachedFiles(targets);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Queued ${targets.length} file${targets.length == 1 ? '' : 's'} for upload'),
        action: SnackBarAction(
          label: 'View',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CopypartyImportPage())),
        ),
      ),
    );
    setState(() => _selected.clear());
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final total = entries?.fold<int>(0, (s, e) => s + e.sizeBytes) ?? 0;
    final budgetMb = ref.watch(appConfigProvider.select((c) => c.copyparty.cacheSizeMb));
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
                    '${entries.length} cached file${entries.length == 1 ? '' : 's'} · '
                    '${formatHumanReadableBytes(total, 1)} used of ${budgetMb ~/ 1024} GiB budget',
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
                            separatorBuilder: (_, __) => const Divider(height: 1),
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
                                      'cached ${DateFormat.yMd().add_Hm().format(e.modified.toLocal())}',
                                      style: context.textTheme.bodySmall,
                                    ),
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
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: () => _upload(selectedEntries),
                              icon: const Icon(Icons.cloud_upload_outlined),
                              label: Text('Upload ${selectedEntries.length}'),
                              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                            ),
                          ),
                          const SizedBox(width: 12),
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
