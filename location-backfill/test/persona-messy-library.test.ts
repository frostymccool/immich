/**
 * Persona A — "The messy real-world library"
 *
 * A photo collection that's been through phones, cameras, and years of exports:
 * burst-mode duplicates, missing metadata, and a trip across the date line.
 * This persona stress-tests matcher.ts + backfill.ts against real photo-data
 * shapes, not clean synthetic input.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decideFill } from '../src/matcher.js';
import type { AssetResponseDto } from '@immich/sdk';

function asset(id: string, isoTime: string, latitude: number | null, longitude: number | null): AssetResponseDto {
  return { id, exifInfo: { dateTimeOriginal: isoTime, latitude, longitude } } as AssetResponseDto;
}

test('burst-mode sibling at the exact same instant is treated as one source, not two', () => {
  // Inclusive window bounds mean a same-timestamp sibling can legitimately come back
  // as both "nearest before" and "nearest after" from the search layer.
  const sibling = asset('sibling', '2026-07-01T10:00:00Z', 51.5, -0.1);
  const fill = decideFill(new Date('2026-07-01T10:00:00Z'), sibling, sibling);
  assert.equal(fill.method, 'copied', 'must not report "interpolated" between an asset and itself');
  if (fill.method === 'copied') {
    assert.equal(fill.source, 'sibling');
  }
});

test('a target with no dateTimeOriginal cannot be matched against — this is exercised via backfill.ts, not matcher.ts', () => {
  // matcher.ts only ever runs once backfill.ts has already confirmed dateTimeOriginal
  // exists; recorded here as documentation of that division of responsibility.
  assert.ok(true);
});

test('KNOWN LIMITATION: interpolation does not handle the antimeridian', () => {
  // Someone travelling from Fiji (~+179.9) to Samoa (~-171) crosses the date line.
  // Naive linear interpolation walks the "wrong way round" through longitude 0
  // instead of the short way through +/-180, landing the estimate on the opposite
  // side of the planet. Pinned here as a known, undressed limitation rather than
  // silently wrong: if this starts failing, it means someone "fixed" it without
  // updating this test or the README's limitations section.
  const before = asset('before', '2026-07-01T10:00:00Z', -17.7, 179.9);
  const after = asset('after', '2026-07-01T11:00:00Z', -17.7, -171.8);
  const fill = decideFill(new Date('2026-07-01T10:30:00Z'), before, after);
  assert.equal(fill.method, 'interpolated');
  if (fill.method === 'interpolated') {
    // The naive midpoint lands near longitude 4, on the opposite side of Earth from
    // the true midpoint near the date line (~176). Asserting the "wrong" value on
    // purpose — this is the bug, pinned so it can't regress silently into "different
    // wrong" without the test failing.
    assert.ok(
      fill.longitude > -1 && fill.longitude < 10,
      `expected the known-buggy antimeridian midpoint, got ${fill.longitude}`,
    );
  }
});

test('null-island convention matches the existing mobile app heuristic (0,0 treated as "no GPS")', () => {
  // mobile/lib/domain/models/exif.model.dart's hasCoordinates getter uses the same
  // rule; kept consistent rather than "fixed" independently on the server side.
  const nullIsland = asset('null-island', '2026-07-01T10:00:00Z', 0, 0);
  const fill = decideFill(new Date('2026-07-01T10:30:00Z'), nullIsland, null);
  // decideFill trusts its caller to have already filtered candidates by hasCoordinates;
  // this documents that hasCoordinates (in immich.ts) is the actual gate — decideFill
  // itself will happily "copy" 0,0 if handed it directly, which is why the exclusion
  // has to happen upstream, not here.
  assert.equal(fill.method, 'copied');
});
