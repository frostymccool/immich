import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/pages/copyparty/copyparty_cleanup.page.dart';
import 'package:immich_mobile/pages/copyparty/copyparty_import.page.dart';
import 'package:immich_mobile/providers/copyparty/copyparty.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';
import 'package:immich_mobile/widgets/settings/setting_group_title.dart';
import 'package:immich_mobile/widgets/settings/setting_list_tile.dart';
import 'package:immich_mobile/widgets/settings/settings_sub_page_scaffold.dart';
import 'package:share_plus/share_plus.dart';

class CopypartySettings extends ConsumerWidget {
  const CopypartySettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const SettingsSubPageScaffold(
      settings: [
        SettingGroupTitle(title: 'Copyparty Server', icon: Icons.cloud_upload_outlined),
        _HostUrlTile(),
        _PasswordTile(),
        _UploadPathTile(),
        _SelfSignedCertTile(),
        _ConnectTestButton(),
        Divider(),
        SettingGroupTitle(title: 'Upload Behaviour', icon: Icons.tune_rounded),
        _ParallelConnectionsSlider(),
        _AutoDeleteTile(),
        Divider(),
        SettingGroupTitle(title: 'File Matching', icon: Icons.link_rounded),
        _TriggerExtensionsTile(),
        Divider(),
        SettingGroupTitle(title: 'Import', icon: Icons.sd_card_rounded),
        _ImportFromMemoryCardButton(),
        _PendingCleanupTile(),
        Divider(),
        SettingGroupTitle(title: 'Diagnostics', icon: Icons.bug_report_outlined),
        _DiagnosticLogTile(),
      ],
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
            style: context.textTheme.bodySmall?.copyWith(
              color: context.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
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
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => _clearLog(context, ref),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Clear'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
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
    final box = context.findRenderObject() as RenderBox?;
    await Share.shareXFiles(
      [XFile(path)],
      subject: 'Copyparty diagnostic log',
      sharePositionOrigin:
          box != null ? box.localToGlobal(Offset.zero) & box.size : null,
    );
  }

  Future<void> _clearLog(BuildContext context, WidgetRef ref) async {
    await ref.read(copypartyLoggerProvider).clear();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Diagnostic log cleared')),
      );
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
          onSave: (value) => ref.read(settingsProvider).write(
            SettingsKey.copypartyHostUrl,
            value.trim(),
          ),
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
        subtitle: password.maybeWhen(
          data: (pw) => pw.isEmpty ? 'Not set' : '••••••••',
          orElse: () => 'Loading...',
        ),
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
          decoration: const InputDecoration(
            hintText: 'Leave empty for no password',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
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
          onSave: (value) => ref.read(settingsProvider).write(
            SettingsKey.copypartyUploadPath,
            value.trim(),
          ),
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
          onChanged: (v) => ref.read(settingsProvider).write(
            SettingsKey.copypartyParallelConnections,
            v.toInt(),
          ),
          onChangeEnd: (v) => ref.read(settingsProvider).write(
            SettingsKey.copypartyParallelConnections,
            v.toInt(),
          ),
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
          onChanged: (v) => ref.read(settingsProvider).write(
            SettingsKey.copypartyAutoDeleteAfterVerify,
            v,
          ),
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
            ref.read(settingsProvider).write(SettingsKey.copypartyTriggerExtensions, list);
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
    final uploading = ref.watch(
      importSessionProvider.select((s) => s.step == ImportSessionStep.uploading),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: FilledButton.icon(
        onPressed: isConfigured
            ? () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CopypartyImportPage()),
              )
            : null,
        icon: Icon(uploading ? Icons.cloud_upload_rounded : Icons.sd_card_rounded),
        label: Text(uploading ? 'Show active uploads' : 'Import from Memory Card'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
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
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
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

class _PendingCleanupTile extends ConsumerWidget {
  const _PendingCleanupTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(pendingCleanupProvider);
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (receipts) {
        if (receipts.isEmpty) {
          return const SizedBox.shrink();
        }
        final count = receipts.length;
        return Padding(
          padding: const EdgeInsets.only(left: 8.0),
          child: SettingListTile(
            title: 'Delete uploaded source files',
            subtitle: '$count file${count == 1 ? '' : 's'} uploaded and awaiting deletion',
            leading: Badge(
              label: Text('$count'),
              child: const Icon(Icons.cleaning_services_rounded),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CopypartyCleanupPage()),
            ),
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
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (result != null) {
    onSave(result);
  }
}
