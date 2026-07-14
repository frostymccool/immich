# location-backfill

Standalone sidecar that fills missing GPS coordinates on Immich assets by copying or
interpolating from nearby-in-time assets that already have a GPS fix. Runs entirely
against Immich's public REST API — no Immich server code is touched, and it never
needs direct database access.

Two ways it runs:

- **Real-time**, via an Immich v3 workflow: trigger = asset metadata extraction, action
  = "Trigger Webhook" pointed at this service's `/webhook`. Fires once per asset the
  moment it's known whether that asset has GPS.
- **Nightly sweep**, for the backlog of assets uploaded before the workflow existed,
  and as a safety net if a webhook delivery is ever lost. Skips itself if anything was
  uploaded in the last `SKIP_SWEEP_IF_UPLOADED_WITHIN_MINUTES` minutes.

Both paths call the same matching logic (`src/matcher.ts`, `src/backfill.ts`):

- Look for the nearest asset with GPS within `MATCH_WINDOW_MINUTES` before and after the
  target's `dateTimeOriginal`.
- One side only → copy its coordinates.
- Both sides → linear time-weighted interpolation between the two.
- Neither → leave it alone.

It does **not** fill `city`/`state`/`country` — there's no public API field to set them
directly, and the update endpoint doesn't re-run reverse geocoding. Coordinates only.

## ⚠️ Before relying on the webhook path

The exact JSON shape Immich's "Trigger Webhook" step POSTs hasn't been confirmed against
a live payload. `src/webhook.ts`'s `extractAssetId` tries a few plausible field paths and
logs the full raw body either way. On first real delivery, check the container logs —
if the id isn't found, the log line will show you the actual shape so `extractAssetId`
can be corrected in one place.

## Setup

1. **API key** — in Immich, create a personal API key with only `asset.read` and
   `asset.update` permissions.
2. **Workflow** — in Immich, create a workflow:
   - Trigger: asset metadata extraction
   - Step: "Trigger Webhook" → `http://location-backfill:8080/webhook`, method `POST`,
     header `x-webhook-secret` = the same value as `WEBHOOK_SECRET` below.
3. **Environment** — copy `.env.example` to `.env` and fill in `IMMICH_API_KEY` and
   `WEBHOOK_SECRET`.
4. **Add to your compose file** (joins the same network as `immich-server` automatically
   since it's the same compose project):

   ```yaml
     location-backfill:
       container_name: immich_location_backfill
       build: ./location-backfill
       env_file:
         - ./location-backfill/.env
       depends_on:
         - immich-server
       restart: always
       healthcheck:
         disable: false
   ```

## Endpoints

- `POST /webhook` — called by the Immich workflow. Requires `x-webhook-secret` header.
- `POST /sweep` — trigger a backlog sweep on demand. Requires `x-webhook-secret` header.
- `GET /healthz` — for the Docker healthcheck.

## Local development

```
npm install
npm run dev
```
