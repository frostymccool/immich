import { config } from './config.js';
import { hasRecentUploads, iterateAssetsMissingLocation } from './immich.js';
import { processAsset } from './backfill.js';
import type { BackfillResult } from './backfill.js';
import type { AssetResponseDto } from '@immich/sdk';

export type SweepReport = { filled: number; skipped: number; errored: number };

export type SweepDeps = {
  hasRecentUploads: (minutes: number) => Promise<boolean>;
  iterateAssetsMissingLocation: () => AsyncGenerator<AssetResponseDto>;
  processAsset: (assetId: string) => Promise<BackfillResult>;
};

const defaultDeps: SweepDeps = { hasRecentUploads, iterateAssetsMissingLocation, processAsset };

let sweepInProgress = false;

export async function runSweep(deps: SweepDeps = defaultDeps): Promise<SweepReport> {
  if (sweepInProgress) {
    console.log('[sweep] skipped — a sweep is already in progress');
    return { filled: 0, skipped: 0, errored: 0 };
  }

  sweepInProgress = true;
  try {
    return await doSweep(deps);
  } finally {
    sweepInProgress = false;
  }
}

async function doSweep(deps: SweepDeps): Promise<SweepReport> {
  if (await deps.hasRecentUploads(config.skipSweepIfUploadedWithinMinutes)) {
    console.log('[sweep] skipped — uploads within the last', config.skipSweepIfUploadedWithinMinutes, 'minutes');
    return { filled: 0, skipped: 0, errored: 0 };
  }

  let filled = 0;
  let skipped = 0;
  let errored = 0;

  for await (const asset of deps.iterateAssetsMissingLocation()) {
    // One asset failing (deleted mid-sweep, a transient API error) must not abort
    // the rest of the run — isolate it, count it, and keep going.
    let result: BackfillResult;
    try {
      result = await deps.processAsset(asset.id);
    } catch (error) {
      errored++;
      console.error(`[sweep] ${asset.id}: failed —`, error);
      continue;
    }

    if (result.method === 'skipped') {
      skipped++;
    } else {
      filled++;
      console.log(`[sweep] ${asset.id}: ${result.method}`);
    }
  }

  console.log(`[sweep] complete — filled ${filled}, skipped ${skipped}, errored ${errored}`);
  return { filled, skipped, errored };
}
