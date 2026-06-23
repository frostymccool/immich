import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/pages/common/large_leading_tile.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

// Fetches candidates with actual file sizes, sorted if sortSmallestFirst is enabled.
final _candidatesWithSizeProvider = FutureProvider.autoDispose<List<(LocalAsset, int)>>((ref) async {
  final candidates = await ref.watch(driftBackupCandidateProvider.future);
  final storage = ref.read(storageRepositoryProvider);
  final sortSmallest = ref.watch(appConfigProvider.select((c) => c.backup.sortSmallestFirst));

  final sizeMap = <String, int>{};
  var si = 0;
  Future<void> fetchSize() async {
    while (true) {
      final i = si;
      if (i >= candidates.length) {
        break;
      }
      si++;
      final asset = candidates[i];
      try {
        final file = await storage.getFileForAsset(asset.id);
        sizeMap[asset.id] = file != null ? await file.length() : 0;
      } catch (_) {
        sizeMap[asset.id] = 0;
      }
    }
  }

  await Future.wait(List.generate(8, (_) => fetchSize()));

  final list = candidates.map((a) => (a, sizeMap[a.id] ?? 0)).toList();
  if (sortSmallest) {
    list.sort((x, y) => x.$2.compareTo(y.$2));
  }
  return list;
});

@RoutePage()
class DriftBackupAssetDetailPage extends ConsumerWidget {
  const DriftBackupAssetDetailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(_candidatesWithSizeProvider);
    return Scaffold(
      appBar: AppBar(title: Text('backup_controller_page_remainder'.t(context: context))),
      body: result.when(
        data: (List<(LocalAsset, int)> candidates) {
          return ListView.separated(
            padding: const EdgeInsets.only(top: 16.0),
            separatorBuilder: (context, index) => Divider(color: context.colorScheme.outlineVariant),
            itemCount: candidates.length,
            itemBuilder: (context, index) {
              final (asset, fileSize) = candidates[index];
              final albumsAsyncValue = ref.watch(driftCandidateBackupAlbumInfoProvider(asset.id));
              final assetMediaRepository = ref.watch(assetMediaRepositoryProvider);
              return FutureBuilder<String?>(
                future: assetMediaRepository.getOriginalFilename(asset.id),
                builder: (context, snapshot) {
                  final displayName = snapshot.data ?? asset.name;
                  return LargeLeadingTile(
                    title: Text(
                      displayName,
                      style: context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w500, fontSize: 16),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          asset.createdAt.toString(),
                          style: TextStyle(fontSize: 13.0, color: context.colorScheme.onSurfaceSecondary),
                        ),
                        Text(
                          fileSize > 0 ? formatHumanReadableBytes(fileSize, 1) : '—',
                          style: TextStyle(fontSize: 13.0, color: context.colorScheme.onSurfaceSecondary),
                        ),
                        albumsAsyncValue.when(
                          data: (albums) {
                            if (albums.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return Text(
                              albums.map((a) => a.name).join(', '),
                              style: context.textTheme.labelLarge?.copyWith(color: context.primaryColor),
                              overflow: TextOverflow.ellipsis,
                            );
                          },
                          error: (error, stackTrace) => Text(
                            'error_saving_image'.tr(args: [error.toString()]),
                            style: TextStyle(color: context.colorScheme.error),
                          ),
                          loading: () =>
                              const SizedBox(height: 16, width: 16, child: CircularProgressIndicator.adaptive()),
                        ),
                      ],
                    ),
                    leading: ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(12)),
                      child: SizedBox(
                        width: 64,
                        height: 64,
                        child: Thumbnail.fromAsset(asset: asset, size: const Size(64, 64), fit: BoxFit.cover),
                      ),
                    ),
                    trailing: const Padding(
                      padding: EdgeInsets.only(right: 24, left: 8),
                      child: Icon(Icons.image_search),
                    ),
                    onTap: () async {
                      await context.maybePop();
                      await context.navigateTo(const TabShellRoute(children: [MainTimelineRoute()]));
                      EventStream.shared.emit(ScrollToDateEvent(asset.createdAt));
                    },
                  );
                },
              );
            },
          );
        },
        error: (Object error, StackTrace stackTrace) {
          return Center(child: Text('error_saving_image'.tr(args: [error.toString()])));
        },
        loading: () {
          return const SizedBox(height: 48, width: 48, child: Center(child: CircularProgressIndicator.adaptive()));
        },
      ),
    );
  }
}
