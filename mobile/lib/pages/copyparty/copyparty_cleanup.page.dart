import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/copyparty/copyparty.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
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

class _CopypartyCleanupPageState extends ConsumerState<CopypartyCleanupPage> {
  List<CopypartyReceipt> _existing = [];
  Set<int> _selected = {};
  Map<int, ServerFileVerification> _verify = {};
  final Set<int> _verifying = {};
  final Set<int> _uploading = {};
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
        _verify = {
          for (final r in existing)
            r.id!: ServerFileVerification(immichApplicable: r.immichAssetId != null),
        };
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
    if (!mounted) return;
    setState(() {
      _verify[id] = f(_verify[id] ?? const ServerFileVerification());
    });
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
      if (r.immichAssetId == null) {
        _mergeVerify(r.id!, (cur) => cur.copyWith(immichApplicable: false));
        continue;
      }
      VerifyState immich;
      try {
        final assetId = await immichAssetIdByChecksum(api, r.localPath);
        immich = assetId != null ? VerifyState.yes : VerifyState.no;
      } catch (_) {
        immich = VerifyState.unknown;
      }
      _mergeVerify(r.id!, (cur) => cur.copyWith(immich: immich, immichApplicable: true));
    }
  }

  /// Deep verify for one file: re-hash + handshake (copyparty) and re-check
  /// Immich by checksum. Auto-selects the file if it becomes safe to delete.
  Future<void> _verifyFile(CopypartyReceipt r) async {
    if (_verifying.contains(r.id)) return;
    setState(() => _verifying.add(r.id!));
    final uploader = ref.read(copypartyUploaderProvider);
    final api = ref.read(apiServiceProvider).assetsApi;
    try {
      final cp = await uploader.verifyHash(
        fileUrl: r.copypartyUrl,
        localPath: r.localPath,
        password: _password,
        base: _verify[r.id!] ?? const ServerFileVerification(),
      );
      VerifyState immich = VerifyState.unknown;
      bool applicable = r.immichAssetId != null;
      if (applicable) {
        try {
          immich = (await immichAssetIdByChecksum(api, r.localPath)) != null
              ? VerifyState.yes
              : VerifyState.no;
        } catch (_) {
          immich = VerifyState.unknown;
        }
      }
      if (!mounted) return;
      setState(() {
        _verify[r.id!] =
            cp.copyWith(immich: immich, immichApplicable: applicable);
        _verifying.remove(r.id);
        if (_verify[r.id!]!.safeToDeleteAt(DateTime.now())) {
          _selected.add(r.id!);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _verifying.remove(r.id));
    }
  }

  Future<void> _verifyAll() async {
    for (final r in _existing) {
      if (!mounted) return;
      await _verifyFile(r);
    }
  }

  /// Recovery (Issue 8): re-upload a file whose verification failed, then verify.
  Future<void> _uploadNow(CopypartyReceipt r) async {
    if (_uploading.contains(r.id)) return;
    setState(() => _uploading.add(r.id!));
    final config = ref.read(appConfigProvider).copyparty;
    final uploader = ref.read(copypartyUploaderProvider);
    String? error;
    try {
      await uploader.uploadFile(
        r.localPath,
        config.hostUrl,
        config.uploadPath,
        _password,
        parallelism: config.parallelConnections,
      );
    } catch (e) {
      error = e.toString();
    }
    if (!mounted) return;
    setState(() => _uploading.remove(r.id));
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $error')),
      );
      return;
    }
    await _verifyFile(r);
  }

  Future<void> _deleteSelected() async {
    final now = DateTime.now();
    final toDelete = _existing.where((r) => _selected.contains(r.id)).toList();
    if (toDelete.isEmpty) return;

    final unsafe = toDelete
        .where((r) => !(_verify[r.id]?.safeToDeleteAt(now) ?? false))
        .toList();

    final bool proceed;
    if (unsafe.isEmpty) {
      // All-clear: every selected file is hash-verified on copyparty + Immich-ok.
      final immichBound =
          toDelete.where((r) => _verify[r.id]?.immichApplicable ?? false).length;
      proceed = (await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('Delete ${toDelete.length} source '
                  'file${toDelete.length == 1 ? '' : 's'}?'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AllClearLine('All ${toDelete.length} are hash-verified on copyparty.'),
                  if (immichBound > 0)
                    _AllClearLine('All $immichBound Immich-bound '
                        'file${immichBound == 1 ? '' : 's'} present in Immich.'),
                  const SizedBox(height: 6),
                  Text('This cannot be undone.',
                      style: TextStyle(
                          color: ctx.colorScheme.onSurface.withValues(alpha: 0.6))),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text('Delete all ${toDelete.length}'),
                ),
              ],
            ),
          )) ??
          false;
    } else {
      // Mixed: some selected files are not safe. Warn explicitly.
      proceed = (await showDialog<bool>(
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
    if (proceed != true) return;

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
    final now = DateTime.now();
    final busy = _verifying.isNotEmpty || _uploading.isNotEmpty;
    final allSelectedSafe = _selected.isNotEmpty &&
        _existing
            .where((r) => _selected.contains(r.id))
            .every((r) => _verify[r.id]?.safeToDeleteAt(now) ?? false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pending Cleanup'),
        centerTitle: false,
        actions: [
          if (!_loading && _existing.isNotEmpty)
            TextButton(
              onPressed: busy ? null : _verifyAll,
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
                        'Files are only safe to delete once verified on copyparty '
                        '(and present in Immich, if applicable). Tap "Verify" / '
                        '"Verify all" to re-hash and confirm each file.',
                        style: context.textTheme.bodySmall?.copyWith(
                          color: context.colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _loadExisting,
                        child: ListView.builder(
                          itemCount: _existing.length,
                          itemBuilder: (ctx, i) {
                            final r = _existing[i];
                            return _CleanupTile(
                              receipt: r,
                              isSelected: _selected.contains(r.id),
                              verification: _verify[r.id] ?? const ServerFileVerification(),
                              verifying: _verifying.contains(r.id),
                              uploading: _uploading.contains(r.id),
                              now: now,
                              onVerify: () => _verifyFile(r),
                              onUploadNow: () => _uploadNow(r),
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
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _selected.isEmpty ? null : _deleteSelected,
                            icon: Icon(allSelectedSafe
                                ? Icons.delete_outline_rounded
                                : Icons.warning_amber_rounded),
                            label: Text(
                              _selected.isEmpty
                                  ? 'Select verified files to delete'
                                  : 'Delete ${_selected.length} '
                                      'file${_selected.length == 1 ? '' : 's'}'
                                      '${allSelectedSafe ? '' : ' (unverified!)'}',
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
            Expanded(child: Text(text, style: const TextStyle(color: Colors.green))),
          ],
        ),
      );
}

class _CleanupTile extends StatelessWidget {
  final CopypartyReceipt receipt;
  final bool isSelected;
  final ServerFileVerification verification;
  final bool verifying;
  final bool uploading;
  final DateTime now;
  final VoidCallback onVerify;
  final VoidCallback onUploadNow;
  final ValueChanged<bool?> onChanged;

  const _CleanupTile({
    required this.receipt,
    required this.isSelected,
    required this.verification,
    required this.verifying,
    required this.uploading,
    required this.now,
    required this.onVerify,
    required this.onUploadNow,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final v = verification;
    final safe = v.safeToDeleteAt(now);
    // Verification has been attempted and the copyparty side is NOT good.
    final hashTried = v.hashValidatedAt != null;
    final cpFailed = (v.filenamePresent == VerifyState.no ||
        v.sizeMatches == VerifyState.no ||
        v.partialExists == VerifyState.yes ||
        (hashTried && !v.hashFreshAt(now)));

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
                    _StateChip(label: 'name', state: v.filenamePresent),
                    _StateChip(label: 'size', state: v.sizeMatches),
                    // Affirmative wording (Issue 9): show "partial exists" in red
                    // when one is present; "no partial" in green only when none.
                    if (v.partialExists == VerifyState.yes)
                      const _RawChip(label: 'partial exists', state: VerifyState.no)
                    else
                      _RawChip(label: 'no partial', state: v.partialExists),
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
                    child: Text(v.error!,
                        style: context.textTheme.labelSmall
                            ?.copyWith(color: context.colorScheme.error)),
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: (verifying || uploading) ? null : onVerify,
                      icon: verifying
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 1.5))
                          : Icon(safe ? Icons.verified_rounded : Icons.fingerprint_rounded,
                              size: 16),
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
                                child: CircularProgressIndicator(strokeWidth: 1.5))
                            : const Icon(Icons.cloud_upload_outlined, size: 16),
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
                strokeWidth: 1.5, color: context.colorScheme.onSurfaceVariant),
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

class _ImmichChip extends StatelessWidget {
  final ServerFileVerification verification;
  const _ImmichChip({required this.verification});

  @override
  Widget build(BuildContext context) {
    if (!verification.immichApplicable) {
      return _RawChip(label: 'Immich n/a', state: VerifyState.unknown);
    }
    final (icon, color, text) = switch (verification.immich) {
      VerifyState.yes => (Icons.photo_library_rounded, Colors.green, 'Immich ✓'),
      VerifyState.no => (Icons.image_not_supported_outlined,
          context.colorScheme.error, 'Immich missing'),
      VerifyState.unknown => (Icons.hourglass_empty,
          context.colorScheme.onSurfaceVariant, 'Immich…'),
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
