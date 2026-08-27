# Photobooth

A native macOS photobooth for live events: Canon EOS DSLR over USB, Canon SELPHY
CP1500 for borderless 4×6 prints, a guest screen and an operator console as two
independent windows.

Built with Swift + SwiftUI. No Xcode project — `build.sh` drives `swiftc` and
`clang` directly, and produces a self-contained `.app` and `.dmg`.

## Build

```bash
./build.sh      # → dist/Photobooth.app
./make_dmg.sh   # → dist/Photobooth.dmg
```

Building needs Homebrew's `libgphoto2` and `libexif`. **Running** does not:
`bundle_libs.sh` copies libgphoto2, the Canon PTP2 camera driver and the USB port
driver into `Photobooth.app/Contents/`, rewrites their load paths to
`@loader_path`, and re-signs them. The shipped app has zero references to
`/opt/homebrew`.

```bash
./makeicon.sh                 # regenerate Resources/AppIcon.icns
./shots.sh out/ [--session]   # render the UI offscreen at each breakpoint
```

`shots.sh` builds the same sources against `Tools/main.swift` instead of the app
entry point, so screens and 4×6 layouts can be proofed without a display, a
camera or a printer. `--session` walks a whole session using the demo source.

Requires macOS 14+, Apple Silicon. The bundled dylibs are arm64-only.

## Hardware

**Camera** — `Native/gphoto_shim.c` is a small C wrapper over libgphoto2
(connect, live-view frame, capture, deferred card delete). libgphoto2 is the
supported route for Canon PTP bodies on macOS and needs no Canon SDK licence.
`main.swift` points `CAMLIBS`/`IOLIBS` at the bundled drivers before the first
gphoto call. macOS claims PTP cameras with its own daemon, so the DSLR backend
releases `PTPCamera`/`ptpcamerad` before initialising.

**Printer** — prints go through the macOS print system (CUPS) via `lp`, which
gives a trackable job id and access to the CP1500's `Postcard.Fullbleed` media.
No proprietary SELPHY protocol is implemented.

Two other camera sources exist behind the same `CameraBackendService` protocol:
a UVC/webcam backend, and a demo source that generates test frames. The demo
source paints a large orange **DEMO SOURCE** badge across the guest screen so it
cannot be left selected at an event by mistake.

## Layout

```
Sources/
  main.swift              app entry, two NSWindows, menus, global key handling
  BoothController.swift   session state machine, service wiring
  CameraService.swift     CameraBackendService + DSLR / webcam / demo backends
  PrinterService.swift    CUPS discovery, status polling, job submission
  PhotoStorageService.swift  session tree, crash recovery, disk preflight
  LayoutRenderer.swift    4×6 geometry and drawing, EXIF orientation, mirroring
  UploadService.swift     disk-backed upload queue for the gallery site
  EventCard.swift         Admin cards for events and the gallery site
  SettingsService.swift   JSON settings with forward-compatible loading
  Log.swift               file log + in-app ring buffer
  Models.swift            Photo, SessionRecord, states, AppSettings
  PhotoboothScreen.swift  guest UI (4:3 stage)
  AdminScreen.swift       operator console — Control and Log tabs
  GalleryTab.swift        session history, reprint, delete
  SettingsTab.swift       branding, print geometry, camera notes
  VHSStyle.swift          camcorder OSD: fringed text, scanlines, brackets, lamps
  UIShared.swift          stage, cards, buttons, status chrome
Native/                   libgphoto2 C shim
Tools/                    offscreen screenshot harness, icon generator
```

## Look

Both screens are dressed as a 1990s camcorder: black field, dot-matrix capitals
with VHS colour fringing, scanlines, vignette and a drifting tracking band.

The guest viewfinder carries the OSD a camcorder would — `● REC` and a running
timecode top-left, shot counter and layout top-right, `18:43 / 21.08.2026 FRI`
bottom-left, event name and an `SP` tape gauge bottom-right that empties as the
session runs.

macOS ships no dot-matrix face, so the character is **built rather than set**:
heavy monospaced glyphs at wide tracking, a red/cyan split behind the white and a
little bloom (`VHSText`). Nothing to license, nothing to bundle.

The Admin console speaks the same language — mono uppercase headings and softkeys,
square status lamps, amber and phosphor on black — but it is deliberately the
minimal version: a heading, a rule, and the controls. No scanline overlay, no
panel fills, no corner brackets, no chromatic fringe, no glows. Body copy stays at
normal weight and native controls are left alone, because a panel used at 2am has
to be readable first and atmospheric second.

That is a performance decision as much as a visual one. `VHSText` has a flat path
(`fringe: 0`) that renders one `Text` instead of three plus two blurs and a
shadow, and the console uses `OSDLabel`, which is just monospaced capitals with
tracking.

## Keeping it light

Idle CPU with the console open went from **7.6% to 1.4%** on an M-series Mac. The
measured causes, in order:

- **Repeating lamp animations.** A `repeatForever` pulse redraws its subtree at
  display rate for as long as the window is open. `StatusDot` is now steady.
- **Polling that ran regardless of whether anyone could see it.** `lpstat` was
  spawning two processes every 4s forever; it now backs off to every 15s when the
  printer is idle, and stops entirely when the console is hidden and no session is
  running. The USB bus scan for the camera moved off the main thread onto the
  camera's own serial queue, and only runs while the camera is missing.
- **The full-window scanline canvas and vignette**, removed from the console.

With the webcam backend the figure is higher (~17%), and most of that is macOS,
not this app: any `AVCaptureSession` on a built-in camera drags in Center Stage,
Reactions and face/hand detection across ten Neural Engine threads. The app
disables Center Stage and asks for 720p, and throttles the preview to the
configured frame rate at 960px rather than converting every 1080p frame — but
Reactions is a system setting, switched off in Control Panel › Video Effects. The
DSLR path does not touch AVFoundation at all, so none of this applies at an event.

## Events

Every session belongs to an `EventRecord` — one client booking — so a night's
photographs stay segregated instead of piling into one folder:

```
Pictures/Photobooth/Events/<slug>/event.json
Pictures/Photobooth/Events/<slug>/Sessions/<sessionID>/photo-01.jpg … print.jpg
```

`startSession()` refuses to run without an active event, and the Start button
carries the event name so the wrong client can't be shot against by accident.

Sessions recorded before events existed still live at `Pictures/Photobooth/
Sessions/`. They are read in place and shown under a pseudo-event called
"Unfiled" — nothing on disk is moved behind the operator's back. "File under
event…" in the session detail pane moves one deliberately.

## Gallery upload

`UploadService` pushes finished sessions to [PhotoboothWeb](../PhotoboothWeb).
It is built for venues with no internet: a finished session goes onto a queue
that is written to `Application Support/Photobooth/upload-queue.json`
immediately, and drains whenever the site is next reachable — this launch or
three days later. Retries back off 30s → 15min. The multipart body is streamed
to a temp file so a 40-photo session is never held in memory twice.

## Session state machine

```
IDLE → STARTING → COUNTDOWN → CAPTURING → PHOTO_PREVIEW → NEXT_PHOTO ─┐
                      ↑                                                │
                      └────────────────────────────────────────────────┘
                                    ↓ (last shot)
                    GENERATING_PRINT → PRINTING → COMPLETE → IDLE
```

Every transition happens in `BoothController`; the UI only renders `state`.

## Print layouts

All three render portrait at 4 × 6 in, 1200 × 1800 px at 300 DPI.

| Layout | Photos | Arrangement |
| --- | --- | --- |
| 4 Duplicate Strips | 4 | two identical 2×6 strips side by side |
| 8 Unique Shots | 8 | 2 × 4 grid |
| 4 Photos — Full Page | 4 | hero / pair / hero |

Slots are computed from margin, gutter and footer settings, so changing those in
Admin reflows the print. Photos are centre-cropped to fill (or letterboxed if
`Fit` is chosen) — never stretched. The guest screen draws a dashed guide at the
first slot's aspect so people can see what will be trimmed.

## Reliability notes

- Each JPEG is written to disk before anything else in the workflow continues,
  and the camera card copy is only deleted after that write returns.
- A retake archives the previous frame as `photo-NN.retake-<epoch>.jpg` rather
  than deleting it.
- A session folder missing `session.json` is rebuilt from the files on disk on
  next launch, then the metadata is written back so it is rebuilt only once.
- Reprints of the same session inside 8 seconds are suppressed unless explicitly
  requested, so a double tap cannot burn two sheets of SELPHY paper.
- `Shell.run` drains its pipes on background queues and kills the child on
  timeout; printer status polls off the main thread. A SELPHY that is powered off
  cannot stall the UI.
- Settings load by merging the saved file over the defaults, so a file written by
  an older version keeps its values instead of resetting.

See `SETUP.txt` for the operator-facing guide that ships inside the DMG.
# photobooth-mac
