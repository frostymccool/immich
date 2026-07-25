import {
  init,
  searchAssets,
  getAssetInfo,
  updateAsset,
  pingServer,
  getMyUser,
  AssetOrder,
  type AssetResponseDto,
} from '@immich/sdk';
import { config } from './config.js';

init({ baseUrl: `${config.immichUrl}/api`, apiKey: config.immichApiKey });

/** Basic reachability check — no auth required. */
export async function checkServerReachable(): Promise<void> {
  await pingServer();
}

/** Confirms the API key is valid and returns the account it belongs to. */
export async function checkApiKeyValid(): Promise<{ email: string }> {
  const user = await getMyUser();
  return { email: user.email };
}

export function hasCoordinates(asset: AssetResponseDto): boolean {
  const lat = asset.exifInfo?.latitude;
  const lon = asset.exifInfo?.longitude;
  return lat != null && lon != null && lat !== 0 && lon !== 0;
}

export async function fetchAsset(id: string): Promise<AssetResponseDto> {
  return getAssetInfo({ id });
}

export async function setAssetLocation(id: string, latitude: number, longitude: number): Promise<void> {
  await updateAsset({ id, updateAssetDto: { latitude, longitude } });
}

/** Nearest asset with GPS strictly before `takenAt`, within `windowMinutes`. */
export async function findNearestBefore(takenAt: Date, windowMinutes: number): Promise<AssetResponseDto | null> {
  const takenAfter = new Date(takenAt.getTime() - windowMinutes * 60_000);
  const { assets } = await searchAssets({
    metadataSearchDto: {
      takenAfter: takenAfter.toISOString(),
      takenBefore: takenAt.toISOString(),
      withExif: true,
      order: AssetOrder.Desc,
      size: 50,
    },
  });
  return assets.items.find((asset) => hasCoordinates(asset)) ?? null;
}

/** Nearest asset with GPS strictly after `takenAt`, within `windowMinutes`. */
export async function findNearestAfter(takenAt: Date, windowMinutes: number): Promise<AssetResponseDto | null> {
  const takenBefore = new Date(takenAt.getTime() + windowMinutes * 60_000);
  const { assets } = await searchAssets({
    metadataSearchDto: {
      takenAfter: takenAt.toISOString(),
      takenBefore: takenBefore.toISOString(),
      withExif: true,
      order: AssetOrder.Asc,
      size: 50,
    },
  });
  return assets.items.find((asset) => hasCoordinates(asset)) ?? null;
}

/**
 * Parses the search API's `nextPage` token into the next page number, or `undefined`
 * to stop. Pulled out as a pure function because `Number(x)` on a non-numeric cursor
 * silently produces `NaN` — which is falsy, so an unguarded `while (page)` loop would
 * just stop pagination early with no signal that later assets were never scanned.
 * `logError` defaults to `console.error` but is overridable so tests can assert the
 * warning fires instead of just asserting the stop.
 */
export function parseNextPage(nextPage: string | null, logError: (message: string) => void = console.error):
  | number
  | undefined {
  if (!nextPage) {
    return undefined;
  }
  const next = Number(nextPage);
  if (!Number.isFinite(next)) {
    logError(`[sweep] unexpected nextPage value "${nextPage}" — stopping pagination early`);
    return undefined;
  }
  return next;
}

/** Pages through the whole library, yielding assets missing GPS. Used only by the backlog sweep. */
export async function* iterateAssetsMissingLocation(): AsyncGenerator<AssetResponseDto> {
  let page: number | undefined = 1;
  while (page) {
    const { assets } = await searchAssets({
      metadataSearchDto: { withExif: true, order: AssetOrder.Asc, size: 200, page },
    });
    for (const asset of assets.items) {
      if (!hasCoordinates(asset)) {
        yield asset;
      }
    }
    page = parseNextPage(assets.nextPage);
  }
}

/** True if anything was taken/uploaded within the last `minutes` — used to skip a sweep mid-upload. */
export async function hasRecentUploads(minutes: number): Promise<boolean> {
  const { assets } = await searchAssets({
    metadataSearchDto: {
      createdAfter: new Date(Date.now() - minutes * 60_000).toISOString(),
      size: 1,
    },
  });
  return assets.total > 0;
}
