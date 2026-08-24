> **English** · [中文](README.zh-CN.md)

# JPRadio / 日本ラジオ

An iOS app for listening to Japanese radio with the feel of an FM dial. Swipe left or right
to change stations; the dial is positioned by **actual broadcast frequency**. Includes program
guides, program favorites and reminders, recording and playback, and automatic song
recognition while listening.

Pure SwiftUI, deployment target iOS 17.

## Features

**Listening**
- 116 stations across 14 dials: 6 radiko areas (Tokyo JP13 / Osaka JP27 / Nagoya JP23 /
  Sapporo JP01 / Fukuoka JP40 / Okinawa JP47 — 39 stations) plus 8 ListenRadio areas of
  nationwide community FM (77 stations). Two synthetic dials on top of those:
  **★ Favorites** (appears once you star a station) and **All** (all 116 on one scale).
- **Works outside Japan**: reimplements [rajiko](https://github.com/jackyzy823/rajiko)'s
  radiko `auth1`/`auth2` flow plus GPS coordinate spoofing to get past the region lock.
  ListenRadio is a separate service — direct HLS, no authentication needed.
- Sleep timer, AirPlay, and Now Playing on the lock screen and in Control Center
  (with station logo / cover art).
- Trilingual UI (English / 中文 / 日本語, English by default), switchable any time from
  the 🌐 button at the top.

**Program guide**
- radiko uses the official XML (`v3/program/station/date/...`); ListenRadio uses its own JSON.
- Page ±7 days in either direction; opens scrolled to whatever is on air right now.
- Broadcast days start at 05:00 per Japanese convention, and all times are JST.

**Favorites and reminders**
- ★ favorite a **station** → a "★" area is added at the front of the dial list.
- 🔖 favorite a **program** → collected under the bookmark button at the top of the main
  screen; tapping one opens that station's guide scrolled straight to that program (if it
  isn't on this week's schedule, it keeps looking forward). The key is "station ID + program
  title", so a program that reruns weekly is still recognized tomorrow. Favoriting also
  schedules a local notification; tapping it jumps to the station as the program starts.

**Recording and playback**
- Record the live stream you're listening to by hand; radiko stations can also be
  **scheduled** — using タイムフリー to download the whole episode after it finishes airing
  (far more reliable than "wake the app at the right moment and capture the live stream",
  see Known limitations below).
- The recordings library has a player: scrubbing, ±15 seconds, background playback,
  lock screen controls.

**Song recognition**
- ShazamKit generates the audio fingerprint on device, and the lookup goes to Shazam's own
  `amp.shazam.com` endpoint — so **no paid developer account** is required for the ShazamKit
  catalog entitlement.
- Works both on live streams and on recording playback. On a match, the title / artist /
  album art are laid over the Now Playing card; changing station or track reverts it to the
  station name and logo.

## Building an unsigned IPA (without xcodebuild)

```bash
zsh tools/make_unsigned_ipa.sh
```

Produces `JPRadio-unsigned.ipa` in the repository root. You'll need to sign it yourself with
Sideloadly / AltStore or similar before installing.

## Layout

```
JPRadio/
  JPRadioApp.swift          @main; the stores' @StateObjects, notification routing, background refresh
  Models/
    Station.swift           station/area data tables + in-code trilingual strings (AppLanguage / L / T)
    Theme.swift             theme color constant Color.brand
  Radiko/
    RadikoProfile.swift     Android app impersonation parameters, full key, per-area GPS coordinates
    RadikoAuth.swift        auth1/auth2; tokens cached per area
    RadikoStream.swift      stream URLs, program guide XML, タイムフリー playlist
  ListenRadio/              program guide JSON for community FM
  Player/
    RadioPlayer.swift       AVPlayer live playback + sleep timer + recognition coordination
    ShazamWebMatcher.swift  fingerprint unwrapping, amp.shazam.com request/response
    ColorExtractor.swift    pulls a dominant color out of the station logo for the background
    FavoritesStore.swift    favorite stations
  Recording/
    RadioRecorder.swift     live stream capture + タイムフリー segment download
    RecordingStore.swift    recordings library
    ReservationStore.swift  scheduled recordings and reconciliation
    ReminderStore.swift     program reminders (local notifications)
    FavoriteProgramStore.swift  favorite programs
  Views/                    TunerView (main screen), FrequencyDialView (the dial),
                            ProgramSheet (program guide), RecordingsSheet, RecordingPlayerView…
tools/                      offline self-checks and packaging scripts (outside the iOS target, never compiled into the app)
channellist.json            the raw ListenRadio station dump the 77 literals in Station.swift came from
```

## Known limitations

- **"Automatically record a live broadcast at a set time" is not possible on iOS.** The system
  makes no guarantee it will wake an app that has been killed at a particular moment. So
  scheduled recording is implemented as "wait for the program to finish airing, then download
  the whole episode via タイムフリー"; live capture only supplements that when the app happens
  to be alive. ListenRadio has no タイムフリー, so those stations are **manual recording only**.

## Credits

- [jackyzy823/rajiko](https://github.com/jackyzy823/rajiko) — radiko authentication and the
  region bypass.
- [shazamio](https://github.com/dotX12/ShazamIO) / [SongRec](https://github.com/marin-m/SongRec)
  — documentation of the Shazam query protocol and fingerprint format.
