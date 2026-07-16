import { config } from './config.js';
import { decideFill } from './matcher.js';
import { checkApiKeyValid, checkServerReachable } from './immich.js';

type CheckResult = { name: string; ok: boolean; detail: string };

/**
 * Three synthetic scenarios covering the three outcomes the matcher can produce,
 * run in-process against the exact same `decideFill` the live service uses — so a
 * green self-test proves the algorithm logic in *this running container*, not just
 * in a dev machine's `npm test`.
 */
function checkAlgorithm(): CheckResult {
  const before = { id: 'a', exifInfo: { dateTimeOriginal: '2026-01-01T10:00:00Z', latitude: 10, longitude: 10 } };
  const after = { id: 'b', exifInfo: { dateTimeOriginal: '2026-01-01T11:00:00Z', latitude: 20, longitude: 20 } };

  const copyBefore = decideFill(new Date('2026-01-01T10:15:00Z'), before as any, null);
  const interpolated = decideFill(new Date('2026-01-01T10:30:00Z'), before as any, after as any);
  const skipped = decideFill(new Date('2026-01-01T10:30:00Z'), null, null);

  const ok =
    copyBefore.method === 'copied' &&
    interpolated.method === 'interpolated' &&
    interpolated.latitude === 15 &&
    skipped.method === 'skipped';

  return {
    name: 'algorithm (copy / interpolate / skip)',
    ok,
    detail: ok
      ? 'all three outcomes matched expected results'
      : `unexpected output: ${JSON.stringify({ copyBefore, interpolated, skipped })}`,
  };
}

async function checkReachable(): Promise<CheckResult> {
  try {
    await checkServerReachable();
    return { name: 'server reachable', ok: true, detail: config.immichUrl };
  } catch (error) {
    return { name: 'server reachable', ok: false, detail: String(error) };
  }
}

async function checkAuth(): Promise<CheckResult> {
  try {
    const { email } = await checkApiKeyValid();
    return { name: 'API key valid', ok: true, detail: `authenticated as ${email}` };
  } catch (error) {
    return { name: 'API key valid', ok: false, detail: String(error) };
  }
}

export async function runSelfTest(): Promise<{ ok: boolean; checks: CheckResult[] }> {
  const checks = [checkAlgorithm(), await checkReachable(), await checkAuth()];
  return { ok: checks.every((c) => c.ok), checks };
}
