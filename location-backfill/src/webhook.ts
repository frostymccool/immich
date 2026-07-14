import type { Request, Response } from 'express';
import { config } from './config.js';
import { processAsset } from './backfill.js';

/**
 * Extracts the asset id from an Immich "Trigger Webhook" payload.
 *
 * The exact JSON shape hasn't been confirmed against a live payload yet (see README) —
 * this tries the field paths that are plausible given Immich's other event payloads,
 * and logs the raw body so the real shape can be read from container logs and this
 * function tightened up once confirmed.
 */
function extractAssetId(body: unknown): string | null {
  const b = body as Record<string, any>;
  return b?.asset?.id ?? b?.data?.asset?.id ?? b?.assetId ?? b?.id ?? null;
}

export async function handleWebhook(req: Request, res: Response): Promise<void> {
  if (req.header('x-webhook-secret') !== config.webhookSecret) {
    res.sendStatus(401);
    return;
  }

  console.log(`[webhook] payload: ${JSON.stringify(req.body)}`);

  const assetId = extractAssetId(req.body);
  if (!assetId) {
    console.warn('[webhook] could not find an asset id in the payload — see raw payload logged above');
    res.sendStatus(200);
    return;
  }

  try {
    const result = await processAsset(assetId);
    console.log(`[webhook] ${assetId}: ${result.method}`);
    res.sendStatus(200);
  } catch (error) {
    console.error(`[webhook] failed to process ${assetId}:`, error);
    // 200, not 5xx: an unknown/deleted asset id shouldn't cause Immich to retry forever.
    res.sendStatus(200);
  }
}
