import { config } from './config.js';
import { fetchAsset, findNearestAfter, findNearestBefore, hasCoordinates, setAssetLocation } from './immich.js';
import { decideFill, type Fill } from './matcher.js';

export type BackfillResult = { assetId: string; applied: boolean } & Fill;

/** `dryRun: true` computes and returns the fill without writing it back — used by `/preview`. */
export async function processAsset(assetId: string, options: { dryRun?: boolean } = {}): Promise<BackfillResult> {
  const asset = await fetchAsset(assetId);

  if (hasCoordinates(asset)) {
    return { assetId, applied: false, method: 'skipped', reason: 'already has coordinates' };
  }

  const takenAtRaw = asset.exifInfo?.dateTimeOriginal;
  if (!takenAtRaw) {
    return { assetId, applied: false, method: 'skipped', reason: 'no dateTimeOriginal to match against' };
  }
  const takenAt = new Date(takenAtRaw);

  const [before, after] = await Promise.all([
    findNearestBefore(takenAt, config.matchWindowMinutes),
    findNearestAfter(takenAt, config.matchWindowMinutes),
  ]);

  const fill = decideFill(takenAt, before, after);

  if (fill.method !== 'skipped' && !options.dryRun) {
    await setAssetLocation(assetId, fill.latitude, fill.longitude);
  }

  return { assetId, applied: fill.method !== 'skipped' && !options.dryRun, ...fill };
}
