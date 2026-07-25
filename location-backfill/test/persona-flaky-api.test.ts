/**
 * Persona B — "The flaky Immich API"
 *
 * A library big enough that a sweep takes real time, an API that occasionally
 * 500s or gets an asset deleted mid-scan, and an operator who might hit /sweep
 * twice. This persona stress-tests sweep.ts's failure isolation and concurrency
 * handling — the things that only show up when something goes wrong partway
 * through a long-running loop, not on the happy path.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runSweep, type SweepDeps } from '../src/sweep.js';
import { parseNextPage } from '../src/immich.js';
import type { AssetResponseDto } from '@immich/sdk';
import type { BackfillResult } from '../src/backfill.js';

test('a malformed pagination cursor stops the sweep loudly, not silently', () => {
  const warnings: string[] = [];
  const result = parseNextPage('not-a-number', (msg) => warnings.push(msg));
  assert.equal(result, undefined, 'must still stop — there is no valid next page to use');
  assert.equal(warnings.length, 1, 'must log a warning rather than stopping silently');
  assert.match(warnings[0], /unexpected nextPage value/);
});

test('a clean numeric cursor continues pagination with no warning', () => {
  const warnings: string[] = [];
  const result = parseNextPage('3', (msg) => warnings.push(msg));
  assert.equal(result, 3);
  assert.equal(warnings.length, 0);
});

test('null cursor (last page) stops cleanly with no warning', () => {
  const warnings: string[] = [];
  const result = parseNextPage(null, (msg) => warnings.push(msg));
  assert.equal(result, undefined);
  assert.equal(warnings.length, 0);
});

function fakeAsset(id: string): AssetResponseDto {
  return { id } as AssetResponseDto;
}

async function* fakeLibrary(ids: string[]): AsyncGenerator<AssetResponseDto> {
  for (const id of ids) {
    yield fakeAsset(id);
  }
}

test('one asset throwing mid-sweep does not abort the rest of the run', async () => {
  const processed: string[] = [];
  const deps: SweepDeps = {
    hasRecentUploads: async () => false,
    iterateAssetsMissingLocation: () => fakeLibrary(['a', 'b', 'c']),
    processAsset: async (id) => {
      processed.push(id);
      if (id === 'b') {
        throw new Error('simulated 404 — asset deleted mid-sweep');
      }
      return { assetId: id, applied: true, method: 'copied', latitude: 1, longitude: 1, source: 'x' };
    },
  };

  const report = await runSweep(deps);

  assert.deepEqual(processed, ['a', 'b', 'c'], 'must attempt every asset, not stop at the failure');
  assert.deepEqual(report, { filled: 2, skipped: 0, errored: 1 });
});

test('a second sweep started while one is in progress is skipped, not run concurrently', async () => {
  let resolveFirst!: () => void;
  const firstAssetGate = new Promise<void>((resolve) => {
    resolveFirst = resolve;
  });
  const concurrentCallCount = { value: 0 };

  const slowDeps: SweepDeps = {
    hasRecentUploads: async () => false,
    iterateAssetsMissingLocation: () => fakeLibrary(['a']),
    processAsset: async (id): Promise<BackfillResult> => {
      concurrentCallCount.value++;
      await firstAssetGate; // block until the test releases it
      return { assetId: id, applied: true, method: 'copied', latitude: 1, longitude: 1, source: 'x' };
    },
  };

  const firstRun = runSweep(slowDeps);
  // Give the first run a tick to set the in-progress flag before starting the second.
  await new Promise((r) => setImmediate(r));

  const secondRun = await runSweep(slowDeps);
  assert.deepEqual(secondRun, { filled: 0, skipped: 0, errored: 0 }, 'overlapping sweep must be a no-op');
  assert.equal(concurrentCallCount.value, 1, 'the second sweep must not have called processAsset at all');

  resolveFirst();
  const firstReport = await firstRun;
  assert.deepEqual(firstReport, { filled: 1, skipped: 0, errored: 0 });
});

test('sweep is skipped entirely when uploads happened recently', async () => {
  let iterated = false;
  const deps: SweepDeps = {
    hasRecentUploads: async () => true,
    iterateAssetsMissingLocation: () => {
      iterated = true;
      return fakeLibrary([]);
    },
    processAsset: async () => {
      throw new Error('should never be called');
    },
  };

  const report = await runSweep(deps);
  assert.deepEqual(report, { filled: 0, skipped: 0, errored: 0 });
  assert.equal(iterated, false, 'must not even start paging the library when uploads are recent');
});
