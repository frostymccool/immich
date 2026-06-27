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
/// Trust is NOT assumed from a stored "uploaded" flag. Each file is checked
/// against the server live, showing independent evidence:
///   • filename present   • size matches   • no lingering partial
///   • content hash validated (within the last 2 minutes)
/// A file can only be auto-selected / safely deleted once it is STRONGLY
/// verified (present + size + no partial + fresh hash). Anything weaker must be
/// selected and confirmed manually.
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
  Map<int, ServerFileVerification> _verify = {};
  final Set<int> _verifying = {};
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

    final initialStatus = <int, _ImmichStatus>{};
    for (final r in existing) {
      initialStatus[r.id!] = r.immichAssetId != null
          ? _ImmichStatus.checking
          : _ImmichStatus.notApplicable;
    }

    if (mounted) {
      setState(() {
        _existing = existing;
        // Nothing is pre-selected: a file must be strongly verified first.
        _selected = {};
        _immichStatus = initialStatus;
        _verify = {for (final r in existing) r.id!: const ServerFileVerification()};
        _password = password;
        _loading = false;
      });
    }

    _checkImmichStatuses(existing);
    _runPresenceChecks(existing);
  }

  /// Cheap on-load check: a single folder listing per file → presence, size,
  /// and whether a partial is lingering. No re-hashing here.
  Future<void> _runPresenceChecks(List<CopypartyReceipt> receipts) async {
    final uploader = ref.read(copypartyUploaderProvider);
    for (final r in receipts) {
      final v = await uploader.verifyPresence(
        fileUrl: r.copypartyUrl,
        filename: r.filename,
        expectedSize: r.sizeBytes,
        password: _password,
      );
      if (!mounted) return;
      setState(() => _verify[r.id!] = v);
    }
  }

  /// Deep check for one file: re-hash locally and validate against the server.
  Future<void> _verifyHash(CopypartyReceipt r) async {
    if (_verifying.contains(r.id)) return;
    setState(() => _verifying.add(r.id!));
    final uploader = ref.read(copypartyUploaderProvider);
    final v = await uploader.verifyHash(
      fileUrl: r.copypartyUrl,
      localPath: r.localPath,
      password: _password,
      base: _verify[r.id!] ?? const ServerFileVerification(),
    );
    if (!mounted) return;
    setState(() {
      _verify[r.id!] = v;
      _verifying.remove(r.id);
      // Auto-select once strongly verified — this is the only safe auto-select.
      if (v.stronglyVerifiedAt(DateTime.now())) {
        _selected.add(r.id!);
      }
    });
  }

  Future<void> _verifyAll() async {
    for (final r in _existing) {
      if (!mounted) return;
      await _verifyHash(r);
    }
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
    final now = DateTime.now();
    final toDelete = _existing.where((r) => _selected.contains(r.id)).toList();
    if (toDelete.isEmpty) return;

    // Block on anything not strongly verified on the copyparty side — this is
    // the safety net: never silently delete a local original whose server copy
    // we couldn't confirm.
    final unverified = toDelete
        .where((r) => !(_verify[r.id]?.stronglyVerifiedAt(now) ?? false))
        .toList();
    if (unverified.isNotEmpty && mounted) {
      final proceed = await _warn(
        'Not fully verified on copyparty',
        '${unverified.length} selected file${unverified.length == 1 ? '' : 's'} '
            "could not be confirmed as completely and correctly stored on "
            "copyparty (missing, wrong size, a partial exists, or the hash "
            "wasn't validated). Deleting now risks data loss. Delete anyway?",
      );
      if (proceed != true) return;
    }

    // Secondary warning for Immich-tracked files not confirmed present.
    final unconfirmedImmich = toDelete.where((r) {
      if (r.immichAssetId == null) return false;
      return _immichStatus[r.id] != _ImmichStatus.present;
    }).toList();
    if (unconfirmedImmich.isNotEmpty && mounted) {
      final proceed = await _warn(
        'Immich not confirmed',
        '${unconfirmedImmich.length} selected file${unconfirmedImmich.length == 1 ? '' : 's'} '
            'could not be confirmed as present in Immich. Delete anyway?',
      );
      if (proceed != true) return;
    }

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

  Future<bool?> _warn(String title, String body) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
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

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final anyVerifying = _verifying.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pending Cleanup'),
        centerTitle: false,
        actions: [
          if (!_loading && _existing.isNotEmpty)
            TextButton(
              onPressed: anyVerifying ? null : _verifyAll,
              child: const Text('Verify all'),
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
                    Container(
                      width: double.infinity,
                      color: context.colorScheme.surfaceContainer,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text(
                        'Files are only safe to delete once verified on copyparty. '
                        'Tap "Verify" (or "Verify all") to re-hash and confirm each '
                        'file is completely and correctly stored.',
                        style: context.textTheme.bodySmall?.copyWith(
                          color: context.colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _existing.length,
                        itemBuilder: (ctx, i) {
                          final r = _existing[i];
                          final v = _verify[r.id] ?? const ServerFileVerification();
                          return _CleanupTile(
                            receipt: r,
                            isSelected: _selected.contains(r.id),
                            immichStatus: _immichStatus[r.id] ?? _ImmichStatus.notApplicable,
                            verification: v,
                            verifying: _verifying.contains(r.id),
                            now: now,
                            onVerify: () => _verifyHash(r),
                            onChanged: (sel) => setState(() {
                              if (sel == true) {
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
                                  ? 'Select verified files to delete'
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
  final ServerFileVerification verification;
  final bool verifying;
  final DateTime now;
  final VoidCallback onVerify;
  final ValueChanged<bool?> onChanged;

  const _CleanupTile({
    required this.receipt,
    required this.isSelected,
    required this.immichStatus,
    required this.verification,
    required this.verifying,
    required this.now,
    required this.onVerify,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final strong = verification.stronglyVerifiedAt(now);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
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
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _StateChip(
                      label: 'name',
                      state: verification.filenamePresent,
                    ),
                    _StateChip(
                      label: 'size',
                      state: verification.sizeMatches,
                    ),
                    _StateChip(
                      label: 'no partial',
                      // invert: partialExists==yes is BAD, so show red.
                      state: switch (verification.partialExists) {
                        VerifyState.yes => VerifyState.no,
                        VerifyState.no => VerifyState.yes,
                        VerifyState.unknown => VerifyState.unknown,
                      },
                    ),
                    _HashChip(
                      verifying: verifying,
                      validatedFresh: verification.hashFreshAt(now),
                      validatedStale: verification.hashValidatedAt != null &&
                          !verification.hashFreshAt(now),
                    ),
                    _ImmichStatusChip(status: immichStatus),
                  ],
                ),
                if (verification.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      verification.error!,
                      style: context.textTheme.labelSmall
                          ?.copyWith(color: context.colorScheme.error),
                    ),
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: verifying ? null : onVerify,
                      icon: verifying
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 1.5),
                            )
                          : Icon(strong ? Icons.verified_rounded : Icons.fingerprint_rounded,
                              size: 16),
                      label: Text(verifying
                          ? 'Verifying…'
                          : strong
                              ? 'Verified'
                              : 'Verify'),
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

/// A small ✓ / ✗ / ❓ evidence chip.
class _StateChip extends StatelessWidget {
  final String label;
  final VerifyState state;

  const _StateChip({required this.label, required this.state});

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

class _HashChip extends StatelessWidget {
  final bool verifying;
  final bool validatedFresh;
  final bool validatedStale;

  const _HashChip({
    required this.verifying,
    required this.validatedFresh,
    required this.validatedStale,
  });

  @override
  Widget build(BuildContext context) {
    if (verifying) {
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
          Text('hash…',
              style: context.textTheme.labelSmall
                  ?.copyWith(color: context.colorScheme.onSurfaceVariant)),
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
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_library_outlined, size: 13, color: Colors.green),
            const SizedBox(width: 3),
            Text('Immich ✓',
                style: context.textTheme.labelSmall?.copyWith(color: Colors.green)),
          ],
        );
      case _ImmichStatus.missing:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_outlined,
                size: 13, color: context.colorScheme.error),
            const SizedBox(width: 3),
            Text('Immich missing',
                style: context.textTheme.labelSmall
                    ?.copyWith(color: context.colorScheme.error)),
          ],
        );
      case _ImmichStatus.error:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 13, color: context.colorScheme.onSurfaceVariant),
            const SizedBox(width: 3),
            Text('Immich check failed',
                style: context.textTheme.labelSmall
                    ?.copyWith(color: context.colorScheme.onSurfaceVariant)),
          ],
        );
    }
  }
}
