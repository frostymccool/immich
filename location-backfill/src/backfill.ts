import { config } from './config.js';
import { fetchAsset, findNearestAfter, findNearestBefore, hasCoordinates, setAssetLocation } from './immich.js';
import { decideFill, type Fill } from './matcher.js';

export type BackfillResult = { assetId: string } & Fill;

export async function processAsset(assetId: string): Promise<BackfillResult> {
  const asset = await fetchAsset(assetId);

  if (hasCoordinates(asset)) {
    return { assetId, method: 'skipped', reason: 'already has coordinates' };
  }

  const takenAtRaw = asset.exifInfo?.dateTimeOriginal;
  if (!takenAtRaw) {
    return { assetId, method: 'skipped', reason: 'no dateTimeOriginal to match against' };
  }
  const takenAt = new Date(takenAtRaw);

  const [before, after] = await Promise.all([
    findNearestBefore(takenAt, config.matchWindowMinutes),
    findNearestAfter(takenAt, config.matchWindowMinutes),
  ]);

  const fill = decideFill(takenAt, before, after);

  if (fill.method !== 'skipped') {
    await setAssetLocation(assetId, fill.latitude, fill.longitude);
  }

  return { assetId, ...fill };
}
