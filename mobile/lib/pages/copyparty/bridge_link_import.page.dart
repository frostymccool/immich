import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/copyparty/copyparty.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/services/copyparty/bridge_links.service.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

final bridgeLinksServiceProvider = Provider.autoDispose<BridgeLinksService>((ref) {
  final service = BridgeLinksService();
  ref.onDispose(service.dispose);
  return service;
});

/// Paste a shared album link (Google Photos or a Google Drive folder) and let the import bridge add the
/// photos to Immich. The bridge does the downloading and importing; this page sends the link, offers names
/// to pick from and shows the bridge's progress while it is open.
class BridgeLinkImportPage extends ConsumerStatefulWidget {
  const BridgeLinkImportPage({super.key});

  @override
  ConsumerState<BridgeLinkImportPage> createState() => _BridgeLinkImportPageState();
}

class _BridgeLinkImportPageState extends ConsumerState<BridgeLinkImportPage> {
  final _link = TextEditingController();
  BridgeLinkAlbum? _album;
  String? _albumLink;
  String? _name;
  bool _looking = false;
  bool _starting = false;
  String? _error;
  List<BridgeLinkJob>? _jobs;
  String? _jobsError;
  Timer? _poll;

  String get _bridgeUrl => ref.read(appConfigProvider).copyparty.bridgeUrl;
  BridgeLinksService get _service => ref.read(bridgeLinksServiceProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_pasteIfLink());
    unawaited(_refreshJobs());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _link.dispose();
    super.dispose();
  }

  /// Fills the box from the clipboard when it holds a link, so most of the time there is nothing to type.
  Future<void> _pasteIfLink({bool always = false}) async {
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
      if (!mounted) {
        return;
      }
      if (always || (text.startsWith('https://') && _link.text.isEmpty)) {
        _link.text = text;
        setState(() {});
      }
    } catch (_) {}
  }

  Future<void> _refreshJobs() async {
    _poll?.cancel();
    try {
      final jobs = await _service.jobs(_bridgeUrl, currentImmichAccessToken());
      if (!mounted) {
        return;
      }
      setState(() {
        _jobs = jobs;
        _jobsError = null;
      });
      // Faster while something runs; only while this page is open.
      _poll = Timer(Duration(seconds: jobs.any((j) => j.running) ? 3 : 15), () => unawaited(_refreshJobs()));
    } on BridgeLinkException catch (e) {
      if (mounted) {
        setState(() => _jobsError = e.message);
      }
    }
  }

  Future<void> _look() async {
    final link = _link.text.trim();
    if (link.isEmpty || _looking) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _looking = true;
      _error = null;
      _album = null;
    });
    try {
      final album = await _service.inspect(_bridgeUrl, currentImmichAccessToken(), link);
      if (!mounted) {
        return;
      }
      setState(() {
        _album = album;
        _albumLink = link;
        _name = album.suggestions.isEmpty ? null : album.suggestions.first;
      });
    } on BridgeLinkException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) {
        setState(() => _looking = false);
      }
    }
  }

  Future<void> _start() async {
    final link = _albumLink;
    if (link == null || _starting) {
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final job = await _service.start(_bridgeUrl, currentImmichAccessToken(), link, _name ?? '');
      if (!mounted) {
        return;
      }
      setState(() {
        _album = null;
        _albumLink = null;
        _link.clear();
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('The bridge is adding "${job.name}". You can leave this page.')));
      await _refreshJobs();
    } on BridgeLinkException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _typeName() async {
    final controller = TextEditingController(text: _name ?? '');
    final typed = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Album name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('OK')),
        ],
      ),
    );
    controller.dispose();
    if (typed != null && typed.trim().isNotEmpty && mounted) {
      setState(() => _name = typed.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = _album;
    return Scaffold(
      appBar: AppBar(title: const Text('Add from a shared link')),
      body: RefreshIndicator(
        onRefresh: _refreshJobs,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Paste a Google Photos shared album link or a Google Drive folder link. Your import bridge '
              'downloads the photos and videos into your folder, adds them to Immich, then removes its copy. '
              'Nothing is downloaded to this phone.',
              style: context.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _link,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'Shared album link',
                hintText: 'https://photos.app.goo.gl/…',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste_rounded),
                  onPressed: () => unawaited(_pasteIfLink(always: true)),
                ),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => unawaited(_look()),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _link.text.trim().isEmpty || _looking ? null : () => unawaited(_look()),
              icon: _looking
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.search_rounded),
              label: Text(_looking ? 'Looking at the album…' : 'Look at the album'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.error)),
            ],
            if (album != null) ...[const SizedBox(height: 16), _albumCard(album)],
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(child: Text('Your link imports', style: context.textTheme.titleMedium)),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: () => unawaited(_refreshJobs()),
                ),
              ],
            ),
            if (_jobsError != null)
              Text(_jobsError!, style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error))
            else if (_jobs == null)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_jobs!.isEmpty)
              Text('None yet.', style: context.textTheme.bodySmall)
            else
              for (final job in _jobs!) _JobTile(job: job),
          ],
        ),
      ),
    );
  }

  Widget _albumCard(BridgeLinkAlbum album) {
    final days = album.days;
    final when = days.isEmpty ? null : (days.length == 1 ? days.first : '${days.first} to ${days.last}');
    final counts = [
      if (album.photos > 0) '${album.photos} photo${album.photos == 1 ? '' : 's'}',
      if (album.videos > 0) '${album.videos} video${album.videos == 1 ? '' : 's'}',
    ].join(' · ');
    final names = {...album.suggestions, ?_name}.toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(album.title.isEmpty ? 'Shared album' : album.title, style: context.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text([counts, ?when].where((s) => s.isNotEmpty).join(' · '), style: context.textTheme.bodyMedium),
            const SizedBox(height: 12),
            Text('Album name', style: context.textTheme.labelLarge),
            const SizedBox(height: 4),
            PopupMenuButton<String>(
              onSelected: (v) => v == '\u0000type' ? unawaited(_typeName()) : setState(() => _name = v),
              itemBuilder: (_) => [
                for (final n in names) CheckedPopupMenuItem(value: n, checked: n == _name, child: Text(n)),
                const PopupMenuDivider(),
                const PopupMenuItem(value: '\u0000type', child: Text('Type a name…')),
              ],
              child: InputDecorator(
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                child: Row(
                  children: [
                    Expanded(child: Text(_name ?? 'Choose a name')),
                    const Icon(Icons.arrow_drop_down_rounded),
                  ],
                ),
              ),
            ),
            if (album.folder.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Saved first in ${album.folder}/${_name ?? ''} on the NAS, removed once Immich has them.',
                style: context.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _starting ? null : () => unawaited(_start()),
              icon: _starting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download_done_rounded),
              label: Text(_starting ? 'Starting…' : 'Add to Immich'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
          ],
        ),
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  final BridgeLinkJob job;
  const _JobTile({required this.job});

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final (icon, color, label) = switch (job.state) {
      'running' => (Icons.downloading_rounded, scheme.primary, 'Adding'),
      'done' => (Icons.check_circle_outline, Colors.green.shade600, 'Done'),
      'failed' => (Icons.error_outline, scheme.error, 'Failed'),
      'stopped' => (Icons.pause_circle_outline, scheme.tertiary, 'Stopped'),
      _ => (Icons.help_outline, scheme.outline, job.state),
    };
    final lines = [
      '$label · ${job.done} of ${job.total}${job.bytes > 0 ? ' · ${formatBytes(job.bytes)}' : ''}',
      if (job.skipped > 0) '${job.skipped} already there',
      if (job.failed > 0) '${job.failed} could not be downloaded',
      if (job.keptOnNas > 0) '${job.keptOnNas} still on the NAS until Immich has them',
      ?job.error,
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(job.name, style: context.textTheme.titleSmall)),
              ],
            ),
            if (job.running && job.total > 0) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: (job.done + job.skipped + job.failed) / job.total),
            ],
            const SizedBox(height: 6),
            Text(lines.join('\n'), style: context.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
