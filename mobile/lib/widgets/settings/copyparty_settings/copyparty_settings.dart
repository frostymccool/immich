import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/pages/copyparty/copyparty_import.page.dart';
import 'package:immich_mobile/providers/copyparty/copyparty.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';
import 'package:immich_mobile/widgets/settings/setting_group_title.dart';
import 'package:immich_mobile/widgets/settings/setting_list_tile.dart';
import 'package:immich_mobile/widgets/settings/settings_sub_page_scaffold.dart';

class CopypartySettings extends ConsumerWidget {
  const CopypartySettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsSubPageScaffold(
      settings: [
        SettingGroupTitle(title: 'Copyparty Server', icon: Icons.cloud_upload_outlined),
        const _HostUrlTile(),
        const _PasswordTile(),
        const _UploadPathTile(),
        const Divider(),
        SettingGroupTitle(title: 'Upload Behaviour', icon: Icons.tune_rounded),
        const _ParallelConnectionsSlider(),
        const _WriteReceiptsTile(),
        const _AutoDeleteTile(),
        const Divider(),
        SettingGroupTitle(title: 'File Matching', icon: Icons.link_rounded),
        const _TriggerExtensionsTile(),
        const Divider(),
        SettingGroupTitle(title: 'Import', icon: Icons.sd_card_rounded),
        const _ImportFromMemoryCardButton(),
      ],
    );
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

class _WriteReceiptsTile extends ConsumerWidget {
  const _WriteReceiptsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appConfigProvider.select((c) => c.copyparty.writeReceipts));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: 'Write receipt files',
        subtitle: 'Write a .cpreceipt sidecar file next to each uploaded file',
        trailing: Switch(
          value: value,
          onChanged: (v) => ref.read(settingsProvider).write(SettingsKey.copypartyWriteReceipts, v),
        ),
      ),
    );
  }
}

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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: FilledButton.icon(
        onPressed: isConfigured
            ? () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CopypartyImportPage()),
              )
            : null,
        icon: const Icon(Icons.sd_card_rounded),
        label: const Text('Import from Memory Card'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
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
  if (result != null) onSave(result);
}
