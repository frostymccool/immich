import { config } from './config.js';
import { hasRecentUploads, iterateAssetsMissingLocation } from './immich.js';
import { processAsset } from './backfill.js';
import type { BackfillResult } from './backfill.js';

export async function runSweep(): Promise<{ filled: number; skipped: number }> {
  if (await hasRecentUploads(config.skipSweepIfUploadedWithinMinutes)) {
    console.log('[sweep] skipped — uploads within the last', config.skipSweepIfUploadedWithinMinutes, 'minutes');
    return { filled: 0, skipped: 0 };
  }

  let filled = 0;
  let skipped = 0;

  for await (const asset of iterateAssetsMissingLocation()) {
    const result: BackfillResult = await processAsset(asset.id);
    if (result.method === 'skipped') {
      skipped++;
    } else {
      filled++;
      console.log(`[sweep] ${asset.id}: ${result.method}`);
    }
  }

  console.log(`[sweep] complete — filled ${filled}, skipped ${skipped}`);
  return { filled, skipped };
}
