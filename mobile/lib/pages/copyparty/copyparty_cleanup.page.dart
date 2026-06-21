import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/copyparty/copyparty.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:intl/intl.dart';

/// Shows uploaded files still present on device so the user can delete them.
class CopypartyCleanupPage extends ConsumerStatefulWidget {
  const CopypartyCleanupPage({super.key});

  @override
  ConsumerState<CopypartyCleanupPage> createState() => _CopypartyCleanupPageState();
}

class _CopypartyCleanupPageState extends ConsumerState<CopypartyCleanupPage> {
  List<CopypartyReceipt> _existing = [];
  Set<int> _selected = {};
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
      if (await File(r.localPath).exists()) existing.add(r);
    }
    if (mounted) {
      setState(() {
        _existing = existing;
        _selected = existing.map((r) => r.id!).toSet();
        _loading = false;
      });
    }
  }

  Future<void> _deleteSelected() async {
    final toDelete = _existing.where((r) => _selected.contains(r.id)).toList();
    if (toDelete.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Files'),
        content: Text(
          'Permanently delete ${toDelete.length} file${toDelete.length == 1 ? '' : 's'} '
          'from this device? They have already been uploaded to copyparty.',
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

    if (confirm != true) return;

    int deleted = 0;
    final repo = ref.read(copypartyReceiptRepositoryProvider);
    for (final receipt in toDelete) {
      try {
        await File(receipt.localPath).delete();
        await repo.markSourceDeleted(receipt.id!);
        deleted++;
      } catch (_) {}
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted $deleted / ${toDelete.length} files')),
      );
      ref.invalidate(pendingCleanupProvider);
      await _loadExisting();
    }
  }

  @override
  Widget build(BuildContext context) {
    final allSelected = _existing.isNotEmpty && _selected.length == _existing.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pending Cleanup'),
        centerTitle: false,
        actions: [
          if (!_loading && _existing.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                _selected = allSelected ? {} : _existing.map((r) => r.id!).toSet();
              }),
              child: Text(allSelected ? 'Deselect all' : 'Select all'),
            ),
        ],
      ),
      body: _loading
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
                    Expanded(
                      child: ListView.builder(
                        itemCount: _existing.length,
                        itemBuilder: (ctx, i) {
                          final r = _existing[i];
                          final isSelected = _selected.contains(r.id);
                          return CheckboxListTile(
                            value: isSelected,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selected.add(r.id!);
                              } else {
                                _selected.remove(r.id);
                              }
                            }),
                            title: Text(r.filename, style: context.textTheme.bodyMedium),
                            subtitle: Text(
                              '${formatHumanReadableBytes(r.sizeBytes, 1)} · '
                              'uploaded ${DateFormat.yMd().format(r.uploadTimestamp.toLocal())}',
                              style: context.textTheme.bodySmall,
                            ),
                            secondary: const Icon(Icons.insert_drive_file_outlined),
                            controlAffinity: ListTileControlAffinity.leading,
                          );
                        },
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _selected.isEmpty ? null : _deleteSelected,
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: Text(
                              _selected.isEmpty
                                  ? 'Select files to delete'
                                  : 'Delete ${_selected.length} '
                                    'file${_selected.length == 1 ? '' : 's'}',
                            ),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                              backgroundColor: _selected.isEmpty
                                  ? null
                                  : context.colorScheme.error,
                              foregroundColor: _selected.isEmpty
                                  ? null
                                  : context.colorScheme.onError,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
