import type { AssetResponseDto } from '@immich/sdk';

export type Fill =
  | { method: 'copied'; latitude: number; longitude: number; source: string }
  | { method: 'interpolated'; latitude: number; longitude: number; sources: [string, string] }
  | { method: 'skipped'; reason: string };

/**
 * Decides how to fill a target asset's GPS from its nearest time-neighbours.
 * Pure function so it's independent of any API/network shape — matcher tests never need a live server.
 */
export function decideFill(
  targetTakenAt: Date,
  before: AssetResponseDto | null,
  after: AssetResponseDto | null,
): Fill {
  if (!before && !after) {
    return { method: 'skipped', reason: 'no GPS neighbour within the match window' };
  }

  if (before && !after) {
    return {
      method: 'copied',
      latitude: before.exifInfo!.latitude!,
      longitude: before.exifInfo!.longitude!,
      source: before.id,
    };
  }

  if (after && !before) {
    return {
      method: 'copied',
      latitude: after.exifInfo!.latitude!,
      longitude: after.exifInfo!.longitude!,
      source: after.id,
    };
  }

  // Both sides present: linear time-weighted interpolation between the two coordinate pairs.
  const beforeTime = new Date(before!.exifInfo!.dateTimeOriginal!).getTime();
  const afterTime = new Date(after!.exifInfo!.dateTimeOriginal!).getTime();
  const span = afterTime - beforeTime;
  const weight = span === 0 ? 0.5 : (targetTakenAt.getTime() - beforeTime) / span;

  return {
    method: 'interpolated',
    latitude: before!.exifInfo!.latitude! + (after!.exifInfo!.latitude! - before!.exifInfo!.latitude!) * weight,
    longitude: before!.exifInfo!.longitude! + (after!.exifInfo!.longitude! - before!.exifInfo!.longitude!) * weight,
    sources: [before!.id, after!.id],
  };
}
