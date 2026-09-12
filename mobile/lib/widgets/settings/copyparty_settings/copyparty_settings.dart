import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/pages/copyparty/copyparty_cache.page.dart';
import 'package:immich_mobile/pages/copyparty/copyparty_cleanup.page.dart';
import 'package:immich_mobile/pages/copyparty/copyparty_import.page.dart';
import 'package:immich_mobile/providers/copyparty/copyparty.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_mobile/utils/disk_space.dart';
import 'package:immich_mobile/widgets/settings/setting_group_title.dart';
import 'package:immich_mobile/widgets/settings/setting_list_tile.dart';
import 'package:immich_mobile/widgets/settings/settings_sub_page_scaffold.dart';
import 'package:share_plus/share_plus.dart';

class CopypartySettings extends ConsumerWidget {
  /// When false, the "Copyparty Server" connection section is hidden — used for
  /// the simplified page opened from the backup screen, where the server config
  /// lives in the main app settings instead. (item 3)
  final bool showServerConfig;
  const CopypartySettings({super.key, this.showServerConfig = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final debug = ref.watch(appConfigProvider.select((c) => c.copyparty.debugMode));
    // Q4: make settings values long-press selectable + copyable (support).
    return SelectionArea(
      child: SettingsSubPageScaffold(
        settings: [
          if (showServerConfig) ...const [
            SettingGroupTitle(title: 'Copyparty Server', icon: Icons.cloud_upload_outlined),
            _HostUrlTile(),
            _PasswordTile(),
            _UploadPathTile(),
            _SelfSignedCertTile(),
            _ConnectTestButton(),
            Divider(),
          ],
          const SettingGroupTitle(title: 'Upload Behaviour', icon: Icons.tune_rounded),
          const _ParallelConnectionsSlider(),
          const _SortSmallestFirstTile(),
          // "Recreate folder structure" is a set-once, whole-server layout choice
          // (like File Matching below) — it lives on the GLOBAL settings page
          // only; the backup-entry upload page stays simple.
          if (showServerConfig) const _RecreateFolderStructureTile(),
          const _DefaultDestinationTile(),
          const _AutoDeleteTile(),
          const Divider(),
          const SettingGroupTitle(title: 'Phone Cache', icon: Icons.storage_rounded),
          const _StageToLocalTile(),
          const _CacheSizeSlider(),
          const _ManageCacheTile(),
          const Divider(),
          // File Matching is a set-once setting — it lives on the GLOBAL settings
          // page only; the backup-entry upload page stays simple. (batch3 item 4,
          // direction corrected from build 96 feedback)
          if (showServerConfig) ...[
            const SettingGroupTitle(title: 'File Matching', icon: Icons.link_rounded),
            const _TriggerExtensionsTile(),
            const Divider(),
          ],
          const SettingGroupTitle(title: 'Import', icon: Icons.sd_card_rounded),
          const _ImportFromMemoryCardButton(),
          const _PendingCleanupTile(),
          // Diagnostics + the debug toggle only exist on the MAIN settings page
          // (item 5), never on the simplified backup-entry copy.
          if (showServerConfig) ...[
            const Divider(),
            const SettingGroupTitle(title: 'Diagnostics', icon: Icons.bug_report_outlined),
            const _DebugModeTile(),
            // A download-log button is always available; the full share/clear
            // diagnostic tools appear only when debug mode is on.
            if (debug) const _DiagnosticLogTile() else const _DownloadLogButton(),
            // Test-harness credentials: a SEPARATE, delete-capable login for a
            // future scripted test tool — debug-mode only, never read by the
            // normal import/cleanup flow. (test-harness prep)
            if (debug) const _TestHarnessCredentialsTile(),
          ],
          // Clear the Android gesture/nav bar so the last tile (e.g. "Free up
          // space") is never partially hidden behind it. (batch3 item 5)
          SizedBox(height: MediaQuery.paddingOf(context).bottom + 16),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Debug mode toggle + always-available "Download log"
// ---------------------------------------------------------------------------

class _DebugModeTile extends ConsumerWidget {
  const _DebugModeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appConfigProvider.select((c) => c.copyparty.debugMode));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: 'Enable debug mode',
        subtitle:
            'Show self-test and diagnostic-log actions across the '
            'copyparty pages. Leave off for normal use.',
        trailing: Switch(
          value: value,
          onChanged: (v) => ref.read(settingsProvider).write(SettingsKey.copypartyDebugMode, v),
        ),
      ),
    );
  }
}

class _DownloadLogButton extends ConsumerWidget {
  const _DownloadLogButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () async {
            final logger = ref.read(copypartyLoggerProvider);
            final path = await logger.flush();
            if (!context.mounted) {
              return;
            }
            final box = context.findRenderObject() as RenderBox?;
            await Share.shareXFiles(
              [XFile(path)],
              subject: 'Copyparty diagnostic log',
              sharePositionOrigin: box != null ? box.localToGlobal(Offset.zero) & box.size : null,
            );
          },
          icon: const Icon(Icons.download_rounded),
          label: const Text('Download log'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Diagnostic log — share / clear the verbose upload protocol log
// ---------------------------------------------------------------------------

class _DiagnosticLogTile extends ConsumerWidget {
  const _DiagnosticLogTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Text(
            'Every import writes a verbose protocol log (requests, responses, '
            'chunk hashes). Share it after a failed run so the exact server '
            'exchange can be inspected.',
            style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurface.withValues(alpha: 0.6)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _shareLog(context, ref),
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Share log'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => _clearLog(context, ref),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Clear'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _shareLog(BuildContext context, WidgetRef ref) async {
    final logger = ref.read(copypartyLoggerProvider);
    final path = await logger.flush();
    if (!context.mounted) {
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    await Share.shareXFiles(
      [XFile(path)],
      subject: 'Copyparty diagnostic log',
      sharePositionOrigin: box != null ? box.localToGlobal(Offset.zero) & box.size : null,
    );
  }

  Future<void> _clearLog(BuildContext context, WidgetRef ref) async {
    await ref.read(copypartyLoggerProvider).clear();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Diagnostic log cleared')));
    }
  }
}

// ---------------------------------------------------------------------------
// Test-harness credentials — a separate, delete-capable login for a future
// scripted test tool that repeats failure scenarios (chunk drops, broken
// pipes, resume races) against the real server without touching the phone.
// ---------------------------------------------------------------------------

class _TestHarnessCredentialsTile extends ConsumerWidget {
  const _TestHarnessCredentialsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final password = ref.watch(copypartyTestPasswordProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Text(
            'A SEPARATE login with delete access, used only by a scripted test '
            'tool to repeat upload/delete scenarios against the real server '
            'without touching the phone. Never used by normal imports or '
            'cleanup — set this only if you\'re setting up that test harness.',
            style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurface.withValues(alpha: 0.6)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 8.0),
          child: SettingListTile(
            title: 'Test harness password',
            subtitle: password.maybeWhen(data: (pw) => pw.isEmpty ? 'Not set' : '••••••••', orElse: () => 'Loading...'),
            leading: const Icon(Icons.science_outlined),
            onTap: () => _showPasswordDialog(context, ref, password.valueOrNull ?? ''),
          ),
        ),
      ],
    );
  }

  Future<void> _showPasswordDialog(BuildContext context, WidgetRef ref, String current) async {
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Test Harness Password'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Leave empty to unset', border: OutlineInputBorder()),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (result != null) {
      final storage = ref.read(secureStorageRepositoryProvider);
      await storage.write('copyparty_test_password', result);
      ref.invalidate(copypartyTestPasswordProvider);
    }
  }
}

// ---------------------------------------------------------------------------
// Host URL
// ---------------------------------------------------------------------------

class _HostUrlTile extends ConsumerWidget {
  const _HostUrlTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hostUrl = ref.watch(appConfigProvider.select((c) => c.copyparty.hostUrl));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: 'Copyparty host URL',
        subtitle: hostUrl.isEmpty ? 'Tap to configure' : hostUrl,
        leading: const Icon(Icons.link),
        onTap: () => _showTextDialog(
          context,
          title: 'Copyparty Host URL',
          hint: 'https://copyparty.yourdomain.com',
          initialValue: hostUrl,
          onSave: (value) => ref.read(settingsProvider).write(SettingsKey.copypartyHostUrl, value.trim()),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Password
// ---------------------------------------------------------------------------

class _PasswordTile extends ConsumerWidget {
  const _PasswordTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final password = ref.watch(copypartyPasswordProvider);
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: 'Copyparty password',
        subtitle: password.maybeWhen(data: (pw) => pw.isEmpty ? 'Not set' : '••••••••', orElse: () => 'Loading...'),
        leading: const Icon(Icons.lock_outline),
        onTap: () => _showPasswordDialog(context, ref, password.valueOrNull ?? ''),
      ),
    );
  }

  Future<void> _showPasswordDialog(BuildContext context, WidgetRef ref, String current) async {
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Copyparty Password'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Leave empty for no password', border: OutlineInputBorder()),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (result != null) {
      final storage = ref.read(secureStorageRepositoryProvider);
      await storage.write('copyparty_password', result);
      ref.invalidate(copypartyPasswordProvider);
    }
  }
}

// ---------------------------------------------------------------------------
// Upload path
// ---------------------------------------------------------------------------

class _UploadPathTile extends ConsumerWidget {
  const _UploadPathTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uploadPath = ref.watch(appConfigProvider.select((c) => c.copyparty.uploadPath));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: 'Upload path',
        subtitle: uploadPath,
        leading: const Icon(Icons.folder_outlined),
        onTap: () => _showTextDialog(
          context,
          title: 'Upload Path',
          hint: '/uploads',
          initialValue: uploadPath,
          onSave: (value) => ref.read(settingsProvider).write(SettingsKey.copypartyUploadPath, value.trim()),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Parallel connections
// ---------------------------------------------------------------------------

class _ParallelConnectionsSlider extends ConsumerWidget {
  const _ParallelConnectionsSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parallel = ref.watch(appConfigProvider.select((c) => c.copyparty.parallelConnections));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 24.0, top: 8.0),
          child: Text(
            'Parallel chunk connections: $parallel',
            style: context.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
          ),
        ),
        Slider(
          value: parallel.toDouble(),
          min: 1,
          max: 16,
          divisions: 15,
          label: '$parallel',
          onChanged: (v) => ref.read(settingsProvider).write(SettingsKey.copypartyParallelConnections, v.toInt()),
          onChangeEnd: (v) => ref.read(settingsProvider).write(SettingsKey.copypartyParallelConnections, v.toInt()),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Write receipts toggle
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Auto-delete toggle
// ---------------------------------------------------------------------------

class _SortSmallestFirstTile extends ConsumerWidget {
  const _SortSmallestFirstTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appConfigProvider.select((c) => c.copyparty.sortSmallestFirst));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: 'Upload smallest first',
        subtitle:
            'Upload groups in ascending total size, so quick wins land '
            'first on slow connections',
        trailing: Switch(
          value: value,
          onChanged: (v) => ref.read(settingsProvider).write(SettingsKey.copypartySortSmallestFirst, v),
        ),
      ),
    );
  }
}

class _RecreateFolderStructureTile extends ConsumerWidget {
  const _RecreateFolderStructureTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appConfigProvider.select((c) => c.copyparty.recreateFolderStructure));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: 'Recreate folder structure',
        subtitle:
            'Upload into a subfolder named after the picked folder '
            '(preserving any nested folders) instead of the flat upload path',
        trailing: Switch(
          value: value,
          onChanged: (v) => ref.read(settingsProvider).write(SettingsKey.copypartyRecreateFolderStructure, v),
        ),
      ),
    );
  }
}

class _StageToLocalTile extends ConsumerWidget {
  const _StageToLocalTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appConfigProvider.select((c) => c.copyparty.stageToLocalBeforeUpload));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: 'Copy to phone before upload',
        subtitle:
            'Copy each file to phone storage first, then upload from that copy. '
            'Faster on slow/USB cards, lets an upload finish if the card is '
            'removed, and makes an interrupted upload resumable. Falls back to '
            'reading the card directly when phone storage is low.',
        trailing: Switch(
          value: value,
          onChanged: (v) => ref.read(settingsProvider).write(SettingsKey.copypartyStageToLocalBeforeUpload, v),
        ),
      ),
    );
  }
}

class _CacheSizeSlider extends HookConsumerWidget {
  const _CacheSizeSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stagingOn = ref.watch(appConfigProvider.select((c) => c.copyparty.stageToLocalBeforeUpload));
    if (!stagingOn) {
      return const SizedBox.shrink();
    }
    final mb = ref.watch(appConfigProvider.select((c) => c.copyparty.cacheSizeMb));

    // Fetched once when this section mounts (and again if it remounts, e.g.
    // returning from "Manage phone cache") rather than on every slider drag
    // tick — a directory listing per frame while dragging would be wasteful.
    final scannedBytes = useState<int?>(null);
    useEffect(() {
      unawaited(
        ref.read(copypartyStagingProvider).currentCacheBytes().then((v) {
          if (context.mounted) {
            scannedBytes.value = v;
          }
        }),
      );
      return null;
      // ignore: exhaustive_keys
    }, const []);

    // While an import is actively uploading, the provider itself keeps
    // cacheUsedBytes fresh in near-real-time — prefer that over our one-shot
    // scan above, which otherwise goes stale the moment a background import
    // stages/uploads/discards a file while this settings page stays open.
    final importStep = ref.watch(importSessionProvider.select((s) => s.step));
    final liveCacheUsed = ref.watch(importSessionProvider.select((s) => s.cacheUsedBytes));
    final usedBytes = importStep == ImportSessionStep.uploading ? liveCacheUsed : scannedBytes.value;

    // The slider's max used to be a fixed 32 GiB guess, then just "current
    // free space minus a 5 GiB buffer" — but that alone double-counts space
    // the cache ITSELF already occupies: a phone showing "8.7 GiB free" while
    // the cache already holds 15.7 GiB was computing a 3 GiB max, an
    // impossible number below what's already safely sitting on disk right
    // now. Bytes the cache currently occupies would become free again if the
    // cache were cleared, so they belong on the "available for cache" side of
    // the equation: max = free + currentlyCached − buffer. Shared with
    // "Manage phone cache" via sustainableCacheMb() so both pages always
    // agree — they used to compute this independently and could show
    // flatly different numbers for the same setting. Also fetched once on
    // mount — free space is a snapshot, same cadence as the cache-used scan.
    const fallbackMaxGib = 32;
    final freeBytes = useState<int?>(null);
    useEffect(() {
      unawaited(
        freeSpaceBytes().then((v) {
          if (context.mounted) {
            freeBytes.value = v;
          }
        }),
      );
      return null;
      // ignore: exhaustive_keys
    }, const []);
    final maxGib = freeBytes.value == null
        ? fallbackMaxGib
        : (sustainableCacheMb(freeBytes: freeBytes.value!, usedBytes: usedBytes ?? 0) / 1024).floor().clamp(1, 1 << 20);
    // Slider works in whole GiB (1–maxGib); stored as MiB.
    final gib = (mb / 1024).clamp(1, maxGib).round();

    return Padding(
      padding: const EdgeInsets.only(left: 8.0, right: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Phone cache size', style: context.textTheme.bodyLarge),
                Text('$gib GiB', style: context.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'How much phone storage the card-copy cache may use to read ahead. '
              'Bigger = more files copied in advance so uploads never wait on the card.',
              style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
          ),
          if (usedBytes != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Text(
                '${formatHumanReadableBytes(usedBytes, 1)} used now '
                '(${(usedBytes / (mb * 1024 * 1024) * 100).clamp(0, 100).round()}%)',
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          Slider(
            value: gib.toDouble(),
            min: 1,
            max: maxGib.toDouble(),
            divisions: maxGib > 1 ? maxGib - 1 : null,
            label: '$gib GiB',
            onChanged: (v) => ref.read(settingsProvider).write(SettingsKey.copypartyCacheSizeMb, v.round() * 1024),
          ),
          if (freeBytes.value != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Text(
                (usedBytes ?? 0) > 0
                    ? 'Max $maxGib GiB — based on ${formatHumanReadableBytes(freeBytes.value!, 1)} free '
                          '+ ${formatHumanReadableBytes(usedBytes!, 1)} already cached '
                          '(keeps 5 GiB free for the phone).'
                    : 'Max $maxGib GiB — based on ${formatHumanReadableBytes(freeBytes.value!, 1)} free '
                          '(keeps 5 GiB free for the phone).',
                style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _ManageCacheTile extends ConsumerWidget {
  const _ManageCacheTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: 'Manage phone cache',
        subtitle: 'See what is copied to the phone; delete or upload cached files',
        leading: const Icon(Icons.sd_storage_outlined),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CopypartyCachePage())),
      ),
    );
  }
}

class _DefaultDestinationTile extends ConsumerWidget {
  const _DefaultDestinationTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appConfigProvider.select((c) => c.copyparty.defaultDestination));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: 'Default destination',
        subtitle:
            'Where Immich-compatible files (photos/videos) go by default. '
            'Sidecar files (.lrv/.osv…) always default to copyparty only.',
        trailing: DropdownButton<String>(
          value: const ['cpOnly', 'both', 'immichOnly'].contains(value) ? value : 'both',
          underline: const SizedBox.shrink(),
          items: const [
            DropdownMenuItem(value: 'cpOnly', child: Text('CP only')),
            DropdownMenuItem(value: 'both', child: Text('Both')),
            DropdownMenuItem(value: 'immichOnly', child: Text('Immich only')),
          ],
          onChanged: (v) {
            if (v != null) {
              unawaited(ref.read(settingsProvider).write(SettingsKey.copypartyDefaultDestination, v));
            }
          },
        ),
      ),
    );
  }
}

class _AutoDeleteTile extends ConsumerWidget {
  const _AutoDeleteTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appConfigProvider.select((c) => c.copyparty.autoDeleteAfterVerify));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: 'Auto-delete after verify',
        subtitle: 'Delete source files automatically once upload is hash-verified',
        trailing: Switch(
          value: value,
          onChanged: (v) => ref.read(settingsProvider).write(SettingsKey.copypartyAutoDeleteAfterVerify, v),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Trigger extensions
// ---------------------------------------------------------------------------

class _TriggerExtensionsTile extends ConsumerWidget {
  const _TriggerExtensionsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exts = ref.watch(appConfigProvider.select((c) => c.copyparty.triggerExtensions));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: 'Trigger extensions',
        subtitle: exts.map((e) => '.$e').join(', '),
        leading: const Icon(Icons.extension_outlined),
        onTap: () => _showTextDialog(
          context,
          title: 'Trigger Extensions',
          hint: 'lrv, insv, insp',
          initialValue: exts.join(', '),
          onSave: (value) {
            final list = value
                .split(',')
                .map((e) => e.trim().toLowerCase().replaceAll('.', ''))
                .where((e) => e.isNotEmpty)
                .toList();
            unawaited(ref.read(settingsProvider).write(SettingsKey.copypartyTriggerExtensions, list));
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Import from memory card button
// ---------------------------------------------------------------------------

class _ImportFromMemoryCardButton extends ConsumerWidget {
  const _ImportFromMemoryCardButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hostUrl = ref.watch(appConfigProvider.select((c) => c.copyparty.hostUrl));
    final isConfigured = hostUrl.isNotEmpty;
    // FB6: while a background upload is running, this becomes "Show active
    // uploads" and reverts automatically when it finishes.
    final uploading = ref.watch(importSessionProvider.select((s) => s.step == ImportSessionStep.uploading));

    if (!uploading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: FilledButton.icon(
          onPressed: isConfigured
              ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CopypartyImportPage()))
              : null,
          icon: const Icon(Icons.sd_card_rounded),
          label: const Text('Import from Memory Card'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      );
    }
    // Split while an import is running: "Show" jumps straight to the
    // progress screen (the old combined button's behavior); "Add" queues
    // more folders into it directly, without a detour through the progress
    // screen first just to reach ITS "Add folders" button.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CopypartyImportPage())),
              icon: const Icon(Icons.cloud_upload_rounded),
              label: const Text('Show'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => pickAndAddFoldersToImport(context),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Self-signed certificate toggle
// ---------------------------------------------------------------------------

class _SelfSignedCertTile extends ConsumerWidget {
  const _SelfSignedCertTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appConfigProvider.select((c) => c.copyparty.allowSelfSignedCert));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: 'Allow self-signed certificate',
        subtitle: 'Skip TLS verification (required for local servers with self-signed certs)',
        trailing: Switch(
          value: value,
          onChanged: (v) => ref.read(settingsProvider).write(SettingsKey.copypartySelfSignedCert, v),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Connect test button
// ---------------------------------------------------------------------------

class _ConnectTestButton extends HookConsumerWidget {
  const _ConnectTestButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final testing = useState(false);
    final hostUrl = ref.watch(appConfigProvider.select((c) => c.copyparty.hostUrl));

    Future<void> runTest() async {
      if (testing.value || hostUrl.isEmpty) {
        return;
      }
      testing.value = true;
      try {
        final password = await ref.read(copypartyPasswordProvider.future);
        final uploader = ref.read(copypartyUploaderProvider);
        final error = await uploader.testConnection(hostUrl, password);
        if (!context.mounted) {
          return;
        }
        final ok = error == null;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok ? 'Connected successfully' : error),
            backgroundColor: ok ? Colors.green : context.colorScheme.error,
            duration: const Duration(seconds: 4),
          ),
        );
      } finally {
        testing.value = false;
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: OutlinedButton.icon(
        onPressed: hostUrl.isEmpty || testing.value ? null : runTest,
        icon: testing.value
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.wifi_tethering_rounded),
        label: Text(testing.value ? 'Testing…' : 'Test Connection'),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pending cleanup tile
// ---------------------------------------------------------------------------

class _PendingCleanupTile extends HookConsumerWidget {
  const _PendingCleanupTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // pendingCleanupProvider is a plain FutureProvider: once computed it stays
    // cached until something explicitly invalidates it. Several code paths do
    // that (a fresh receipt, an auto-delete, a manual delete on the cleanup
    // page), but anything outside those — e.g. the USB card being unplugged
    // then reconnected, which changes which receipts' local sources currently
    // exist — can leave this badge showing a stale, too-low count while the
    // full Pending Cleanup page (which always recomputes fresh on open) shows
    // the true number. Invalidating here every time this settings section is
    // built makes the badge behave the same way: always live, never a stale
    // cache from whenever it last happened to be invalidated elsewhere.
    useEffect(() {
      unawaited(Future.microtask(() => ref.invalidate(pendingCleanupProvider)));
      return null;
      // ignore: exhaustive_keys
    }, const []);
    final async = ref.watch(pendingCleanupProvider);
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (receipts) {
        if (receipts.isEmpty) {
          return const SizedBox.shrink();
        }
        final count = receipts.length;
        return Padding(
          padding: const EdgeInsets.only(left: 8.0),
          child: SettingListTile(
            title: 'Free up space — delete uploaded source files',
            subtitle: '$count file${count == 1 ? '' : 's'} uploaded and awaiting deletion',
            leading: Badge(label: Text('$count'), child: const Icon(Icons.cleaning_services_rounded)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CopypartyCleanupPage())),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Shared dialog helpers
// ---------------------------------------------------------------------------

Future<void> _showTextDialog(
  BuildContext context, {
  required String title,
  required String hint,
  required String initialValue,
  required void Function(String) onSave,
}) async {
  final controller = TextEditingController(text: initialValue);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder()),
        autofocus: true,
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
      ],
    ),
  );
  if (result != null) {
    onSave(result);
  }
}
