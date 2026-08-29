> **English** · [中文](README.zh-CN.md)

# JPRadio / 日本ラジオ

Listen to Japanese radio with the feel of an FM dial — **radiko** (auth1/auth2 + GPS spoofing
to get past the region lock, plus タイムフリー archive playback) and **ListenRadio** (nationwide
community FM, direct HLS). Swipe or drag the dial — it's positioned by **actual broadcast
frequency**. Program guides, station/program favorites, sleep timer, and automatic song
recognition while listening, in English / 中文 / 日本語.

Two front ends sharing one station table:

- **iOS app** — pure SwiftUI, deployment target iOS 17. Adds program reminders and a full
  recordings library with scheduled recording.
- **web version** (`web/`) — a local Node reverse proxy serving a same-origin static page, so
  any browser on your machine can listen. Zero third-party dependencies, one Node process.

## Screenshots

<p>
  <img src="docs/screenshots/ios-tuner.png" alt="Tuner / FM dial" width="30%">
  <img src="docs/screenshots/ios-schedule.png" alt="Program guide" width="30%">
  <img src="docs/screenshots/ios-recognize.png" alt="Song recognition" width="30%">
</p>

> Drop your three iOS screenshots into `docs/screenshots/` as `ios-tuner.png`,
> `ios-schedule.png`, `ios-recognize.png` (see [docs/screenshots/README.md](docs/screenshots/README.md)).

## iOS app

**Listening**
- 116 stations across 14 dials: 6 radiko areas (Tokyo JP13 / Osaka JP27 / Nagoya JP23 /
  Sapporo JP01 / Fukuoka JP40 / Okinawa JP47 — 39 stations) plus 8 ListenRadio areas of
  nationwide community FM (77 stations). Two synthetic dials on top: **★ Favorites** and
  **All** (all 116 on one scale).
- **Works outside Japan**: reimplements [rajiko](https://github.com/jackyzy823/rajiko)'s
  radiko `auth1`/`auth2` flow plus GPS coordinate spoofing. ListenRadio is a separate service —
  direct HLS, no authentication needed.
- Sleep timer, AirPlay, and Now Playing on the lock screen and in Control Center.
- Trilingual UI (English / 中文 / 日本語), switchable any time from the 🌐 button.

**Program guide** — radiko's official XML and ListenRadio's JSON, ±7 days, opens on whatever
is on air now. Broadcast days start at 05:00 (Japanese convention); all times JST.

**Favorites and reminders** — ★ favorite a **station** (adds a "★" dial) or 🔖 favorite a
**program** (collected at the top; tapping opens the guide at that program). Program favorites
key on "station ID + program title", so a weekly rerun is still recognized, and schedule a
local notification that jumps to the station as it starts.

**Recording and playback** — record the live stream by hand; radiko stations can also be
**scheduled** (using タイムフリー to download the whole episode after it airs — far more reliable
than waking the app at the right moment; see Known limitations). The library has a player with
scrubbing, ±15s, background playback, and lock-screen controls.

**Song recognition** — ShazamKit generates the fingerprint on device and the lookup goes to
Shazam's own `amp.shazam.com` endpoint, so **no paid catalog entitlement** is required. Works on
live streams and on recording playback; on a match the title / artist / art overlays the card.

## Web version

Listen from any browser on your machine — same stations, same design, plus recording and
scheduled recording (the always-on Node process makes both possible). On a phone it's a single
radio; the wider the window, the more it fans out — a station list column at ≥980px, plus an
always-on program guide column at ≥1200px (three equal-height columns, each scrolling on its
own). See [web/README.md](web/README.md) for the full write-up.

```bash
node web/server.mjs                        # → http://127.0.0.1:8787
node web/server.mjs --host 0.0.0.0         # also reachable from phones/tablets on your LAN
node web/server.mjs --port 9000 --rec-dir /Volumes/ext/rec
```

Needs Node 18+ (uses the built-in `fetch`). Safari plays HLS natively; other browsers use hls.js
pulled from a CDN by the page.

**Configuration.** There's almost nothing to configure — the design is "local proxy + static
front end", and it reads what it needs from the repo:

- **radiko geo-bypass key**: extracted at startup from `ios/JPRadio/Radiko/RadikoProfile.swift`
  (the 167 KB key lives in exactly one place). If the Android key isn't found it falls back to
  the public `pc_html5` key, which only works from a Japanese IP. The startup banner and
  `/api/health` say which mode is active.
- **station table**: `web/public/stations.json`, exported from `ios/JPRadio/Models/Station.swift`.
  Re-export with `zsh web/sync-stations.sh` after editing the Swift table.
- **flags**: `--host` (default `127.0.0.1`), `--port` (default `8787`), `--rec-dir` (default
  `web/recordings/`).

⚠️ **No authentication.** `--host 0.0.0.0` exposes it to your LAN: anyone on the network can
listen through your IP and hit the record/delete endpoints (which write to your disk). Only run
it on a network you trust, and never port-forward it to the public internet.

Why a server at all (a static page can't do this): radiko / ListenRadio send no CORS headers;
HLS playlist requests need `X-Radiko-AuthToken` while segment requests must *not* have it;
ListenRadio's CDN enforces Referer/Origin; and the geo-bypass must send a spoofed GPS header.
All of that has to happen server-side.

## Building an unsigned IPA (without xcodebuild)

```bash
zsh tools/make_unsigned_ipa.sh
```

Produces `JPRadio-unsigned.ipa` in the repository root. Sign it yourself with Sideloadly /
AltStore or similar before installing.

## Layout

```
ios/                            the SwiftUI app (open ios/JPRadio.xcodeproj)
  JPRadio/
    JPRadioApp.swift            @main; stores, notification routing, background refresh
    Models/                     Station.swift (data + trilingual strings), Theme.swift
    Radiko/                     RadikoProfile / RadikoAuth / RadikoStream (auth, GPS, streams)
    ListenRadio/                program guide JSON for community FM
    Player/                     RadioPlayer, ShazamWebMatcher, ColorExtractor, FavoritesStore
    Recording/                  RadioRecorder, RecordingStore, ReservationStore, ReminderStore…
    Views/                      TunerView, FrequencyDialView, ProgramSheet, RecordingsSheet…
  JPRadio.xcodeproj/
web/                            the browser version (Node reverse proxy + static front end)
  server.mjs                    the only server process; routing + reverse proxy
  lib/                          radiko auth, m3u8 rewriting, program guide, recording, Shazam…
  public/                       static front end (index.html / style.css / app.js / dial.js…)
  test/                         offline self-checks
docs/screenshots/               README thumbnails
tools/                          offline self-checks and packaging scripts (never compiled in)
channellist.json                the raw ListenRadio dump the 77 literals in Station.swift came from
```

The iOS project references its sources by relative path, so `JPRadio/` and `JPRadio.xcodeproj/`
were moved into `ios/` **together** — no project-file edit was needed.

## Known limitations

- **"Automatically record a live broadcast at a set time" is not possible on iOS.** The system
  won't guarantee waking a killed app at a given moment, so scheduled recording waits for the
  program to finish and downloads the whole episode via タイムフリー; live capture only
  supplements that when the app is alive. ListenRadio has no タイムフリー, so those stations are
  **manual recording only**. (The web version's always-on process doesn't have this limitation.)

## Credits

- [jackyzy823/rajiko](https://github.com/jackyzy823/rajiko) — radiko authentication and the
  region bypass.
- [shazamio](https://github.com/dotX12/ShazamIO) / [SongRec](https://github.com/marin-m/SongRec)
  — documentation of the Shazam query protocol and fingerprint format.
