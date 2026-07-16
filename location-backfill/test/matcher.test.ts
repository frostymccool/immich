import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decideFill } from '../src/matcher.js';
import type { AssetResponseDto } from '@immich/sdk';

function assetWithGps(id: string, isoTime: string, latitude: number, longitude: number): AssetResponseDto {
  return {
    id,
    exifInfo: { dateTimeOriginal: isoTime, latitude, longitude },
  } as AssetResponseDto;
}

test('copies from the only neighbour when just "before" is within the window', () => {
  const before = assetWithGps('before-1', '2026-07-01T10:00:00Z', 51.5, -0.1);
  const fill = decideFill(new Date('2026-07-01T10:30:00Z'), before, null);
  assert.equal(fill.method, 'copied');
  assert.deepEqual(fill, { method: 'copied', latitude: 51.5, longitude: -0.1, source: 'before-1' });
});

test('copies from the only neighbour when just "after" is within the window', () => {
  const after = assetWithGps('after-1', '2026-07-01T11:00:00Z', 48.8, 2.3);
  const fill = decideFill(new Date('2026-07-01T10:30:00Z'), null, after);
  assert.equal(fill.method, 'copied');
  assert.deepEqual(fill, { method: 'copied', latitude: 48.8, longitude: 2.3, source: 'after-1' });
});

test('interpolates between two neighbours, weighted by elapsed time', () => {
  const before = assetWithGps('before-1', '2026-07-01T10:00:00Z', 0, 0.0);
  const after = assetWithGps('after-1', '2026-07-01T11:00:00Z', 10, 10);
  // Exactly halfway in time between the two neighbours.
  const fill = decideFill(new Date('2026-07-01T10:30:00Z'), before, after);
  assert.equal(fill.method, 'interpolated');
  if (fill.method === 'interpolated') {
    assert.equal(fill.latitude, 5);
    assert.equal(fill.longitude, 5);
    assert.deepEqual(fill.sources, ['before-1', 'after-1']);
  }
});

test('weights the interpolation toward the closer neighbour, not always the midpoint', () => {
  const before = assetWithGps('before-1', '2026-07-01T10:00:00Z', 0, 0);
  const after = assetWithGps('after-1', '2026-07-01T11:00:00Z', 10, 10);
  // 12 minutes after "before", 48 minutes before "after" — should sit near the "before" end.
  const fill = decideFill(new Date('2026-07-01T10:12:00Z'), before, after);
  assert.equal(fill.method, 'interpolated');
  if (fill.method === 'interpolated') {
    assert.equal(fill.latitude, 2);
    assert.equal(fill.longitude, 2);
  }
});

test('skips when neither side has a neighbour within the window', () => {
  const fill = decideFill(new Date('2026-07-01T10:30:00Z'), null, null);
  assert.equal(fill.method, 'skipped');
});
