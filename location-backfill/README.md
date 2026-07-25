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
- `GET /selftest` — diagnostics, see below. Requires `x-webhook-secret` header.
- `GET /preview/:id` — dry run for one asset, see below. Requires `x-webhook-secret` header.
- `GET /healthz` — for the Docker healthcheck.

## Testing it

Three ways to check this is working, in order of how much you trust it so far:

1. **Algorithm correctness, no live server needed:**
   ```
   npm test
   ```
   Three test suites, each a persona built to stress a different layer:
   - `test/persona-messy-library.test.ts` — a real photo library's mess: burst-mode
     siblings sharing one timestamp, missing EXIF fields, a trip across the
     antimeridian. Tests `matcher.ts`/`backfill.ts`.
   - `test/persona-flaky-api.test.ts` — one asset failing mid-sweep, a malformed
     pagination cursor, two overlapping sweeps. Tests `sweep.ts`/`immich.ts`.
   - `test/persona-hostile-caller.test.ts` — endpoints hit without the secret,
     malformed JSON, whether the process survives a real backend failure. Tests
     `app.ts` over HTTP via `supertest`.
   - `test/matcher.test.ts` — the base copy/interpolate/skip cases.

   Two bugs these caught and fixed along the way, worth knowing about:
   - A GPS-tagged asset sharing the *exact* timestamp of the target it's filling
     (common in burst mode) could come back as both "nearest before" and "nearest
     after" from the same search, since the date-range filters are inclusive on
     both ends — `decideFill` used to read that as an interpolation between an
     asset and itself. Now recognized as a single source and reported as `copied`.
   - `sweep.ts` used to let one asset throwing (deleted mid-sweep, a transient
     API error) abort the entire run, silently leaving every asset after it
     unprocessed. It now isolates failures per-asset and reports an `errored`
     count alongside `filled`/`skipped`.

   One thing deliberately *not* fixed, pinned by a test instead so it can't
   regress into something worse: interpolating across the antimeridian (e.g. Fiji
   to Samoa) computes the geographically wrong midpoint, the same way the
   flight-across-the-ocean case can produce an implausible average. Both are
   symptoms of the same gap — there's no plausibility guard on the interpolation
   distance/bearing. Worth adding if you have assets that cross either.

2. **Is the deployed container wired up correctly?**
   ```
   curl -H "x-webhook-secret: <your secret>" http://<host>:8080/selftest
   ```
   Runs the same three algorithm scenarios *inside the running container*, then checks the
   server is reachable and the API key authenticates. All three checks must pass; `ok: true`
   in the response means the container itself is healthy end-to-end.

3. **Will it do the right thing to a real photo, without changing anything?**
   ```
   curl -H "x-webhook-secret: <your secret>" http://<host>:8080/preview/<asset-id>
   ```
   Runs the exact matching logic for one real asset — including the live search for
   neighbours — and returns what it *would* do (`copied` / `interpolated` / `skipped`,
   with the source asset id(s) and coordinates) without writing anything back. Pick an
   asset id from your library that's missing GPS and is near other GPS-tagged photos in
   time, and confirm the result looks right before trusting the webhook/sweep to apply it
   for real.

## Local development

```
npm install
npm run dev
npm test
```
