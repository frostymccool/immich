import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/copyparty/copyparty.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:intl/intl.dart';
import 'package:openapi/api.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shows uploaded files still present on device so the user can delete them.
///
/// Each entry shows:
/// - Tappable link to the file on the copyparty server
/// - Real-time Immich presence check (if the file was also uploaded to Immich)
class CopypartyCleanupPage extends ConsumerStatefulWidget {
  const CopypartyCleanupPage({super.key});

  @override
  ConsumerState<CopypartyCleanupPage> createState() => _CopypartyCleanupPageState();
}

/// Immich check result per receipt id.
enum _ImmichStatus { checking, present, missing, notApplicable, error }

class _CopypartyCleanupPageState extends ConsumerState<CopypartyCleanupPage> {
  List<CopypartyReceipt> _existing = [];
  Set<int> _selected = {};
  Map<int, _ImmichStatus> _immichStatus = {};
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

    final initialStatus = <int, _ImmichStatus>{};
    for (final r in existing) {
      initialStatus[r.id!] = r.immichAssetId != null
          ? _ImmichStatus.checking
          : _ImmichStatus.notApplicable;
    }

    if (mounted) {
      setState(() {
        _existing = existing;
        _selected = existing.map((r) => r.id!).toSet();
        _immichStatus = initialStatus;
        _loading = false;
      });
    }

    // Kick off background Immich checks after UI is shown.
    _checkImmichStatuses(existing);
  }

  Future<void> _checkImmichStatuses(List<CopypartyReceipt> receipts) async {
    final assetsApi = ref.read(apiServiceProvider).assetsApi;
    for (final r in receipts) {
      if (r.immichAssetId == null) continue;
      _ImmichStatus result;
      try {
        final asset = await assetsApi.getAssetInfo(r.immichAssetId!);
        result = asset != null ? _ImmichStatus.present : _ImmichStatus.missing;
      } on ApiException catch (e) {
        result = e.code == 404 ? _ImmichStatus.missing : _ImmichStatus.error;
      } catch (_) {
        result = _ImmichStatus.error;
      }
      if (mounted) {
        setState(() => _immichStatus[r.id!] = result);
      }
    }
  }

  Future<void> _deleteSelected() async {
    // Warn if any selected files haven't been confirmed in Immich but need it.
    final unconfirmedImmich = _existing.where((r) {
      if (!_selected.contains(r.id)) return false;
      if (r.immichAssetId == null) return false;
      return _immichStatus[r.id] != _ImmichStatus.present;
    }).toList();

    if (unconfirmedImmich.isNotEmpty && mounted) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Immich Not Confirmed'),
          content: Text(
            '${unconfirmedImmich.length} selected file${unconfirmedImmich.length == 1 ? '' : 's'} '
            '${unconfirmedImmich.length == 1 ? 'could' : 'could'} not be confirmed as present in '
            'Immich. Delete anyway?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: ctx.colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete Anyway'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    final toDelete = _existing.where((r) => _selected.contains(r.id)).toList();
    if (toDelete.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Files'),
        content: Text(
          'Permanently delete ${toDelete.length} file${toDelete.length == 1 ? '' : 's'} '
          'from this device?',
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
                          final immich = _immichStatus[r.id] ?? _ImmichStatus.notApplicable;
                          return _CleanupTile(
                            receipt: r,
                            isSelected: isSelected,
                            immichStatus: immich,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selected.add(r.id!);
                              } else {
                                _selected.remove(r.id);
                              }
                            }),
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
                              backgroundColor:
                                  _selected.isEmpty ? null : context.colorScheme.error,
                              foregroundColor:
                                  _selected.isEmpty ? null : context.colorScheme.onError,
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

class _CleanupTile extends StatelessWidget {
  final CopypartyReceipt receipt;
  final bool isSelected;
  final _ImmichStatus immichStatus;
  final ValueChanged<bool?> onChanged;

  const _CleanupTile({
    required this.receipt,
    required this.isSelected,
    required this.immichStatus,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      value: isSelected,
      onChanged: onChanged,
      title: Text(receipt.filename, style: context.textTheme.bodyMedium),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${formatHumanReadableBytes(receipt.sizeBytes, 1)} · '
            'uploaded ${DateFormat.yMd().format(receipt.uploadTimestamp.toLocal())}',
            style: context.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _StatusChip(
                icon: Icons.cloud_done_outlined,
                label: 'copyparty',
                color: context.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              _ImmichStatusChip(status: immichStatus),
            ],
          ),
        ],
      ),
      secondary: IconButton(
        icon: const Icon(Icons.open_in_browser_outlined, size: 20),
        tooltip: 'Open in copyparty',
        onPressed: () async {
          final uri = Uri.tryParse(receipt.copypartyUrl);
          if (uri != null) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
      ),
      controlAffinity: ListTileControlAffinity.leading,
    );
  }
}

class _StatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatusChip({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
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

class _ImmichStatusChip extends StatelessWidget {
  final _ImmichStatus status;

  const _ImmichStatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case _ImmichStatus.notApplicable:
        return const SizedBox.shrink();
      case _ImmichStatus.checking:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              'Immich…',
              style: context.textTheme.labelSmall?.copyWith(
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      case _ImmichStatus.present:
        return _StatusChip(
          icon: Icons.photo_library_outlined,
          label: 'Immich ✓',
          color: Colors.green,
        );
      case _ImmichStatus.missing:
        return _StatusChip(
          icon: Icons.image_not_supported_outlined,
          label: 'Immich missing',
          color: context.colorScheme.error,
        );
      case _ImmichStatus.error:
        return _StatusChip(
          icon: Icons.cloud_off_outlined,
          label: 'Immich check failed',
          color: context.colorScheme.onSurfaceVariant,
        );
    }
  }
}
