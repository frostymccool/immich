# Changelog

Versions are shown in the page header, `GET /healthz`, the start-up log line and the phone app's bridge tile
(header also shows the installed commit).

## 0.11.1 - newest uploads corrected first; plainer skip reason

- Automatic correction takes the newest imports first (still in import order within a pass), so what was just
  uploaded is corrected before the older backlog.
- A file type Immich does not accept is listed as "Immich does not take .<ext> files; kept on the NAS" instead of
  "unsupported extension".

## 0.11.0 - automatic correction of wrong camera clocks

- Automatic correction (`AUTO_FIX`) now also corrects the TIME, not only the place, when the evidence is strong:
  - The file proves its clock: GoPro HERO11 and later store their zone and a UTC clock (read without scanning the
    video), which Immich reads as a local time and shows hours off; Insta360 names + tags as before. The instant, and
    the zone Immich shows it in, are corrected even without a place, including for files that already have one.
  - A clip exported without the zone tag follows the clips numbered within 5 of it whose UTC clock their files prove.
  - A camera whose clock is wrong or has no zone (DSLRs, compacts): its pictures in a folder are matched with
    pictures of the same moment from devices with a trusted clock, using Immich's own image model
    (`IMMICH_ML_URL`). At least 3 pairs must agree within 3 minutes; the offset then applies to every file of that
    camera in that folder. Found on a real trip: a DSLR left on another zone, 8 h 11 min behind UTC, from 13 shots
    matching a GoPro's.
- The place of an outing: when no geotagged photo is within 30 minutes, geotagged photos within 3 hours that look like
  that camera's pictures, all agreeing on one spot, give the place.
- Every change goes to a `changes` log (asset, field, old, new, why); `GET /api/geofix/auto` lists each camera's clock
  decision (`clocks`). A file whose time or place was guessed is never used as evidence for another guess.
- After updating, every file waiting for review, or marked as already placed, is looked at again once.
- New settings: `AUTO_FIX_SAME_MOMENT` (0.85), `AUTO_FIX_LOOKS_LIKE` (0.75). The bridge reads metadata again
  (`READER_VERSION` 6).

## 0.10.0 - add photos from a shared album link

- New card on the Status tab, "Add photos from a shared link": paste a Google Photos shared album link
  (photos.app.goo.gl / photos.google.com/share) or a Google Drive folder link. Pasting is enough: the bridge reads the
  album and shows how many photos and videos it holds, their days, and up to 4 album names, the first already
  chosen: `<town> <date>` (the town of your own geotagged Immich photos taken at the same time), the same with the
  camera, the album's own title with its date, and its plain title. Tap another, or edit the name, then Import.
- The originals (full quality, Google's download, file names as the owner uploaded them) are saved into a new
  folder with that name inside the person's own upload folder, and each is imported as soon as it lands. The folder
  name becomes the Immich album, and the usual corrections apply (Fix locations, automatic place and time).
- Once Immich has the same bytes (checked by asset or checksum) and automatic correction has finished with the file,
  or `LINK_KEEP_DAYS` (7) days have passed, the NAS copy is deleted; the folder goes too once it is empty. Only files
  the bridge downloaded itself are ever deleted, never anything else in that folder. A file changed on the NAS after
  the import, or missing from Immich, is kept.
- Nothing is overwritten: a file already there with the same bytes is skipped (pasting a link twice is harmless), a
  different file with the same name is saved under a new name. Only https links to Google's own hosts are read, and
  downloads only follow redirects that stay on them.
- Needs the data mounted read-write: run the installer once with `WRITABLE=1`. The installer now remembers
  `WRITABLE=1` on later runs and updates (`WRITABLE=0` turns it off again).
- API: `POST /api/links/inspect`, `POST /api/links/import` (`name` optional: the first suggestion), `GET /api/links`.
  With the bridge token (`user` picks the person), or with `X-Immich-Token`, which always acts for that signed-in
  person only, so the phone app can offer the same.

## 0.9.0 - camera XMP sidecars go to Immich with their photo

- When a photo has an XMP sidecar next to it (from the camera, Lightroom, darktable...), the bridge sends it with
  the upload, so the rating, title, description, keywords and any GPS or date in it show in Immich. Matching, in the
  photo's own folder and ignoring case: `<file name>.xmp` (DSC_0042.NEF.xmp), else `<name without extension>.xmp`
  (P1010001.xmp, which then goes with both P1010001.ORF and P1010001.JPG). The same rules as the phone app (build 300).
- With a place and time chosen on the Fix locations tab as well, both go in one sidecar: the camera's rating,
  keywords and caption are kept, the chosen place and time replace the camera's GPS and date, and the Fix-locations
  note becomes the description only when the camera has none.
- A RAW photo, or any photo in a folder that holds XMP files, waits up to 45 s (`XMP_WAIT_S`, 0 = never) for its
  sidecar, because the phone uploads them as separate files. A sidecar that still arrives after its photo was
  imported is named in the log. Immich only reads a sidecar with the upload, so photos imported before this version,
  or already in Immich, keep their old details.
- Nothing is written to the files on the NAS; the XMP files themselves stay there (Immich does not take them on their
  own, so they count as skipped).

## 0.8.1 - "Everyone" no longer names one account

- With several people and **Everyone** picked, the Status tab's "Where files come from and go to" said it imported
  into the main person's account and showed only their album count. It now says each person imports into their own
  Immich account, and to pick a person to see which.

## 0.8.0 - each phone sees only its own person

- New `GET /status/me` for the phone app: it sends its Immich sign-in (`X-Immich-Token`), the bridge asks Immich whose
  it is and answers only that person's status (counts, queue, folders, albums, recent files), plus who is signed in.
  401 for a missing or wrong sign-in, 404 for an Immich user with no bridge account, 503 when Immich cannot be asked.
  Answers are remembered for 5 minutes (60 s for a wrong sign-in); the sign-in is never logged or put in a URL.
- The open `/status` no longer shows anybody's folders, albums, file names or auto-correct counts: totals, queue,
  pause and back-off only. The keys are still there, empty, so older app builds keep working. The bridge page sends
  its token and still sees everything.

## 0.7.2 - gentler automatic correction

- Automatic correction now waits 6 s after each change (was 2 s, `AUTO_FIX_PAUSE_S`), so a batch of 50 is spread over
  the 5-minute cycle: about 10 changes a minute, even when the server looks healthy. The Proxmox history for the
  2026-11-23 overload showed the first pass alone (404 changes in 11 minutes) was enough to overload the server, so the
  bridge no longer relies on backing off alone.

## 0.7.1 - health line on the Status tab

- The Status tab always shows a one-line health summary under **Imports**: whether Immich is healthy, the server load
  per CPU and how fast Immich answers (checked every 30 s), auto-correct on/off with how many files it fixed and how
  many wait for evidence, and whether MQTT is connected. `/status` carries the same numbers (`backoff.load`,
  `backoff.ping_s`, `extras.autofix.counts`, `extras.mqtt`); counts only, no names or paths.

## 0.7.0 - backs off when Immich is overloaded; MQTT

- **Backs off by itself** when the server is overloaded (load per CPU of 3 or more, `BACKOFF_LOAD`), Immich is slow
  to answer a ping (5 s, `BACKOFF_PING_S`) or does not answer, or an upload fails with a server error, 429 or timeout.
  No new import or Immich change starts; a file already uploading finishes; waiting files stay queued. Checks wait 1,
  2, 4 ... up to 30 minutes, and work resumes once the load is under 1.5 per CPU (`BACKOFF_LOAD_OK`) and Immich
  answers quickly. The page shows a **Backing off** pill and a banner with the reason and the next check.
- Automatic correction works in batches of 50 with a 2 s pause after each change (`AUTO_FIX_PAUSE_S`): every change
  makes Immich re-read the file, and a large first pass could overload a small server.
- **MQTT** (`mqtt_url` / `MQTT_URL`, off by default): retained state under `ImmichBridge/` (node with a last will,
  queue, paused, backoff with reason and next check, imports, corrections) and events. With `public_url` set, the
  bridge registers itself in an mqtt-netdocs style device index. `GET /llms.txt` (open) describes it all.
- No retained topic is ever published empty (that deletes it on the broker): "none" instead.
- `update-bridge.sh` keeps an install on the branch it came from (recorded as `BRIDGE_BRANCH` by the installer).

## 0.6.0 - automatic place and time zone from your own photos

- **New setting `auto_fix` (`AUTO_FIX`, off by default).** After imports finish, files this bridge imported that have no
  place are compared with the account's geotagged photos. A file is changed only when its true instant is known and
  photos within 30 minutes agree on the place (two photos within 5 km of each other, or one within 10 minutes). The
  same instant is then shown in the local time of that place. Only Immich's metadata changes, never the original.
- Anything else stays as it is, is listed with the reason (`GET /api/geofix/auto`), and is checked again every 6 hours
  because new photos can settle it. Files Immich already had, and other people's accounts, are never changed.
- **Insta360 videos now know their true time.** The stored tag is the instant in UTC and the file name is the wall
  clock in whatever zone the camera was left on, so together they give both. Names without the lens field are now
  recognised too. Before, such a clip could match photos from hours away and be moved by that much when accepted.

## 0.5.2 - the token can be saved by the browser

- The sign-in box is now a real sign-in form (user name `immich-bridge`, the token as password), so Chrome and other
  password managers offer to save it, and the page signs in with a saved one when this browser has forgotten it.

## 0.5.1 - look-alike threshold measured on real footage

- Groups are joined at a CLIP similarity of 0.80 (was 0.85). Measured on real GoPro frames: the same deck six hours
  apart scored 0.86; different scenes of one house scored at most 0.74.

## 0.5.0 - groups by real recording time, look-alike cards, dates for unset clocks

- **Groups follow when recordings really ended.** Video length is now read, and GoPro chapters (GH01/GH02… of one
  number) are one recording whose end comes from the chapters' close times. A time-lapse that plays 5 min but took
  80 min no longer leaves a fake 3-hour gap after it.
- **Look-alike groups become one card** (same folder, within 12 h, frames that Immich's own image recognition finds
  alike). **Split into separate cards** turns them into linked cards with **Use for both**; **Join again** undoes it.
  The installer finds Immich's machine-learning container and attaches the bridge to its network (`IMMICH_ML=off`
  to skip). Without it, groups are split by time only and the page says so.
- **An unset camera clock is no date** (Jan 1 00:00:00, a Jan 1-2 date followed by a much later shot, a date before
  the camera existed, a future date). Undated shots are dated from the camera's file number within one camera and
  folder, and the estimate is sent with a description saying how it was made.
- **A geotagged shot of the same camera, at most 10 file numbers away,** is the first suggestion for a shot without GPS.
- A shot with its own GPS but no usable date keeps its GPS and gets the zone from it.
- "1 of your photo" wording fixed.

## 0.4.4 - a saved place gives its own GPS

- When the exact spot falls inside a place you named, the place's own point is used, not the photos' average:
  phone GPS indoors can drift 100 m+, which put home videos on a neighbour's street. The card says how far the
  photos were from the saved place.

## 0.4.3 - imports with a fixed place work on a real Immich

- An import carrying a place and time (from Fix locations) was refused by Immich with "Unsupported file type": Immich
  checks every uploaded part against the form's `filename`, so the `.xmp` sidecar was judged as the video. When a
  sidecar is sent, `filename` is left out and each part is named by its own file name (same name in Immich).

## 0.4.2 - a sharper exact spot

- The exact spot is now the densest knot of your photos (the photo with most others within 40 m), not the middle of
  every photo nearby: a walk around the block could pull it 150 m away, onto a neighbour's address.
- The exact spot is only pre-selected when its photos are within 60 m and are at least half of the photos nearby;
  otherwise the town is pre-selected (the exact spot is still offered).

## 0.4.1 - layout fix

- The exact spot / town choice was stretched across the card (the page's input width applied to the radio buttons);
  "Name this place…" now sits under the street name.

## 0.4.0 - exact spot or town, time zone names, before and after

- **How exact:** each suggestion offers the **exact spot** where your nearby photos were taken (within about 150 m,
  shown with its accuracy) or just the **town**. Confident suggestions default to the exact spot, less certain ones
  to the town.
- **Street names:** the exact spot is named by a place you saved yourself ("Name this place…", e.g. Home; used for
  any spot within 150 m, in later scans too), otherwise by OpenStreetMap's public reverse geocoder, which is sent
  only that spot's coordinates (cached, at most one request a second). Set `GEOFIX_REVERSE_GEOCODE=off` in the
  bridge's environment to never ask OpenStreetMap.
- **Time zone names:** suggestions show the zone, e.g. `America/Los_Angeles (PDT, UTC-07:00)`, looked up offline
  from the place. Each file gets the offset for its own date, so a group that spans a daylight-saving change is right.
- **Before and after:** each suggestion shows, for one file, the time Immich shows today (a camera clock without a
  zone is read as UTC, so it sits hours off on your timeline) and the time it will show after the fix.
- The photos shown next to a suggestion are labelled as your Immich photos, with when they were taken.
- When Immich has no preview of one of those photos (seen on real videos), the bridge makes one from the original.
- The container adds `tzdata` and the `tzfpy` package (time zone lookup, about 3 MB).

## 0.3.3 - click any preview to enlarge it

- On the Fix locations tab, the small "your photos here" pictures next to each suggestion can now be clicked to
  enlarge them, like the file previews. The enlarged view loads a large picture (a 1280 px frame of the video, or
  Immich's own large preview) instead of stretching the small one. Esc or a click closes it.
- A photo Immich has no preview for shows "?" with an explanation, not an empty box.

## 0.3.2 - rescan reads videos again

- 0.3.1 fixed reading video times, but a rescan still showed "no capture time": the scan keeps what it read per file
  and reused the empty answers saved by 0.3.0. That saved list is now cleared once after updating, so the next scan
  reads every file again. Your accept/skip choices are kept.

## 0.3.1 - Fix locations checked against real camera files

- **Videos were scanned as having no time at all.** GoPro and Insta360 keep the movie header at the end of the file
  and the scan's `-fast2` option made exiftool stop before it. Checked with real exiftool on real HERO9 and Insta360
  files; the option is gone (reading the header costs well under a second even on a 900 MB clip).
- **Insta360 videos now use the clock in their file name** (`VID_20260501_142000_00_001.insv`). Their recorded
  date is that clock already turned into UTC with the zone set in the camera, which was hours off on real files (and
  not always the zone the trip was in), so matching against your photos used the wrong time of day. GoPro videos
  record the wall clock itself and are unchanged.
- The folder picker on the Fix locations tab opens in the chosen person's own folder instead of the top folder;
  **Up** still goes all the way to the top.
- `update-bridge.sh` and `move-copyparty-root.sh` could not replace themselves with a newer copy on a Mac (they used
  a Linux-only `chmod` option); now portable.
- Still not checked: a real Immich reading the sidecar that the bridge sends.

## 0.3.0 - fix missing location and time zone before import

- New **Fix locations** tab (`?t=locations`, also `?t=fix`). Scan a folder: files without GPS or without a time zone
  (typical for GoPro and Insta360) are grouped by folder and time, and for each group the bridge suggests a place and
  time zone from **your own Immich photos taken around the same time**, with those photos shown as evidence and a
  confidence label. Accept one suggestion, accept all confident ones at once, search a place by name, or skip.
- **Files are never changed and nothing is written next to them.** The choice is kept in the bridge's own data folder
  and sent with the file as an XMP sidecar when the bridge imports it. It follows a file that is moved to another
  folder (matched by name and size). "Show what is sent" displays the sidecar.
- A camera clock without a zone is matched by local wall-clock time against your photos, so no time-zone database is
  needed; the neighbour's own zone becomes the suggestion.
- The container now includes `exiftool` (reads the metadata, the same tool Immich uses) and `ffmpeg` (previews), so
  the image is larger and the first build after updating takes longer.
- The API key needs `asset.read` (find nearby photos, search places) and `asset.view` (show them). A key with all
  permissions has both; the page says which one is missing.
- Limits: files already in Immich are not changed (the page says so per group); GPS that a camera stores only inside
  its video data track (GoPro telemetry, Insta360 trailer) is not read, exactly as Immich does not read it.
- Not yet checked against real exiftool output or real camera files: the tests use a stand-in for exiftool (done in 0.3.1).

## 0.2.1 - watched folders follow the person

- *Folders & settings → Watched folders* now follows the person chosen at the top (or `?user=`). In folder-per-person
  mode each person's own folder is fixed (shown as "(their folder)", id hidden); you can add folders **inside** it
  (shown relative to it; the picker cannot leave it) and star one to import it first. Changes apply immediately, no
  Save, and adding a folder inside one the person already has does not pause them. Everyone lists each person's folder;
  the main account's folder is automatic. The server refuses extra folders outside a person's own folder.

## 0.2.0 - several people, folder per person

**What is new**
- **Several Immich accounts in one bridge** (People tab, header switcher): each person has their own API key, folders,
  import records and queue. A file goes to the owner of the most specific folder; for the shared area the uploader's
  copyparty login can decide. New people start paused; *Review & start* hands over files already imported elsewhere.
- **Folder per person**: folders named `<firstname>-<full Immich user id>` in the mounted data folder are detected
  automatically; add a person by picking the first name and pasting their key, and the bridge checks the key's account
  id against the folder name. Nothing to configure; `PEOPLE_ROOT=off` or the page's *Switch off* disables it.
- **Tab and person in the address**: `?t=status|people|settings|logs` opens that tab and `?user=ian` (id, name, Immich name or email) selects that person; clicking a tab or the switcher updates the address, so views can be bookmarked or shared. The folder-selection card is now "Debug folder selection" at the bottom of the People tab. In folder-per-person mode *Edit* shows only the key (name for the main account) and the folder as text, and has a *Remove person…* button.
- **Several copyparty containers** (`EXTRA_COPYPARTY=...`), explicit API-key errors that name missing permissions,
  `update-bridge.sh`, HTTPS-proxy notes.

**What behaves differently (read before updating)**
- *A single-person install needs nothing and behaves as before* (same `state.db`, same `/status` fields).
- With **two or more people**: `/hook` needs `BRIDGE_TOKEN`; the open `/status` shows totals only (no file names or
  errors; per-person detail needs the token); symbolic links out of a person's folder are no longer followed.
- With **folder per person on** (automatic when such folders exist in the data folder): the main account imports **only its own `name-<id>` folder**, no longer
  everything under the data folder; a folder nobody is set up for is imported by nobody; files directly in a person's
  folder get no folder album. Switching it off returns main to the installer's folders.
- New files on the state volume: `users.json` (holds every person's API key, plaintext, mode 600), `router.db`,
  `users/<id>/state.db`. Back them up with the volume; an unreadable `users.json` stops the bridge from starting.
- Environment variables belong between `|` and `bash` (`... install.sh | EXTRA_COPYPARTY=x bash`), not before `curl`.

**Updating**: `~/copyparty/update-bridge.sh` (add `BRANCH=<branch>` while this is not on the default branch).

## 0.1.0 - first release
Watches the copyparty data folder, imports into one Immich account (hook + periodic sweep), web page for settings,
folder albums, pause, account tracking, installer.
