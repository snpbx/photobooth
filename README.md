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
  BrandingAssets.swift    footer artwork imported through Admin
  GIFRenderer.swift       the session's photographs as one looping GIF
  UploadService.swift     disk-backed upload queue for the gallery site
  EventCard.swift         Admin cards for events and the gallery site
  SettingsService.swift   JSON settings with forward-compatible loading
  Log.swift               file log + in-app ring buffer
  Models.swift            Photo, SessionRecord, states, AppSettings
  PhotoboothScreen.swift  guest UI (fills the display; 4:3 metric)
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
minimal version. No scanline overlay, no corner brackets, no chromatic fringe, no
glows. Body copy stays at normal weight and native controls are left alone,
because a panel used at 2am has to be readable first and atmospheric second.

That is a performance decision as much as a visual one. `VHSText` has a flat path
(`fringe: 0`) that renders one `Text` instead of three plus two blurs and a
shadow, and the console uses `OSDLabel`, which is just monospaced capitals with
tracking.

**Navigation runs down the left**, not across the top. On a 1180 × 820 iPad the
console is wider than it is tall, so a vertical rail spends the axis there is
most of and gives each destination a row a thumb can hit — a segmented control
across the top gave every tab a 22pt sliver. The rail also collects what an
operator *glances* at rather than presses — camera, printer, disk — into one
column of caption-over-value readouts, with the booth button at the foot. Below
900pt it drops to icons, since 218pt of navigation out of an 820pt window is a
quarter of the console spent on getting around it.

Cards sit on a surface a shade off the page, so each reads as one thing rather
than a run of rows separated by rules. That surface is a flat fill and a
one-pixel border and nothing else: lifting a card with a shadow would mean an
offscreen blur pass per card on every redraw, which is the cost the console was
stripped of in the first place — and which a screen carried over USB pays for
twice.

## Touch

**Touch controls** (Settings › Interface) sizes the console for a fingertip. It
cannot be detected and is deliberately a preference: an iPad driven as a monitor
delivers its taps to macOS as ordinary mouse clicks, indistinguishable from a
trackpad, so there is nothing for the app to sense.

The target is Apple's 44pt minimum, which on an 11" iPad at 2× is about 8.5mm of
glass — the physical size that number was chosen for on iOS. Measured down the
Session column at 1180 × 820:

| | off | on |
| --- | --- | --- |
| Start Session | 31 pt | 54 pt |
| Retake number | 29 | 51 |
| Restart / Print Session | 28 | 48 |
| Copies | field + 11pt arrows | 51 × 51 buttons |

Copies is ten buttons rather than a field and a stepper: the value only ever runs
1–10, so there is nothing worth typing, and on a touch screen a text field means
the on-screen keyboard covering the panel to enter a single digit.

`controlSize(.large)` does the work for the controls the app does not draw itself
— text fields, the segmented tab bar — and toggles swap from macOS's 14pt
checkbox to the switch style, which is nearer 50 × 30. Every custom button also
gets a `contentShape`, so the gaps between glyphs stop being dead space.

A second, minimal Control tab — session, retakes, layout, copies — was built and
then removed; it is in the history if it is wanted back.

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

**Light rendering** (Admin › Display) is for a booth screen that is not directly
attached — an iPad over USB, a DisplayLink adapter, screen sharing. On those the
whole frame is captured, compressed and shipped every time a pixel moves, so the
cost is *change*, not complexity: a static screen is free and a seven-second
decorative loop is not. The switch stops the drifting tracking band, the blinking
lamps and the OSD colour fringing, which is every animation the guest screen has.
Idle then produces no frames at all. Scanlines and the vignette stay — they are
drawn once and cost nothing to hold.

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

## The GIF — currently off

> **Switched off pending a rework.** `GIFRenderer.enabled` is `false`, which gates
> every place the feature surfaced: building it, the finish screen, the operator's
> gallery, the session page, the album and the uploads. Sessions that already have
> a `session.gif` on disk stay hidden too, rather than half-appearing in one place
> and not another. Nothing has been deleted and no file on disk is touched — set
> the flag to `true` and all of the below comes back as it was. The rest of this
> section describes the feature as built.

Every session also produces `session.gif` — **the print's own layout, animated**.
Each slot on the sheet replays the seconds immediately before its shutter fired,
and they all run at once, so the whole strip moves: every cell shows what those
guests were doing in the run-up to the photograph that ended up in it. Three
seconds at 10 fps by default, played at real speed, looping forever.

The motion can only come from the live view. A shutter yields one still; the
three seconds before it exist nowhere else. So `BoothController` records the
countdown's preview frames per shot, scaling each one down to the size it will
occupy in the finished GIF as it arrives — holding three seconds of 960px preview
for eight shots would be hundreds of megabytes of pixels about to be thrown away.
Two consequences follow: **the moving picture is preview resolution, not sensor
resolution**, and **with live view off there is no GIF at all** — the log says so
rather than the booth failing quietly.

Geometry comes from `LayoutRenderer.composite`, the same call that draws the
print, so the loop and the sheet cannot disagree about slots, cropping or footer.
The GIF's settings carry the print's geometry with `dpi` moved to match the
smaller canvas — margins and type are specified in inches, so without that a
quarter-inch margin becomes a third of a 320px sheet. The QR code is dropped: it
is unreadable at that size, and hard black-and-white detail is the most expensive
thing a 256-colour format can carry, repeated in every frame.

Animating the whole sheet costs far more than a slideshow of stills — thirty
frames rather than four. Measured on photographic content at 3s and 10 fps, the
range covering all three layouts:

| Long edge | File |
| --- | --- |
| 360 px | 1.1 – 1.5 MB |
| **480 px** (default) | **1.9 – 2.5 MB** |
| 640 px | 3.6 – 4.5 MB |

Frame rate scales that in direct proportion. On poor venue wifi, 360 px at 8 fps
is about a third of the default.

The GIF travels with the photographs everywhere they go — the session page, the
encrypted album, Cloudinary — and appears on the finish screen beside the print
so guests know there is one to take before they scan anything. Under **light
rendering** it is shown as a still: the finish screen can be held for minutes,
and a loop running that whole time is exactly the perpetual redraw that mode
exists to remove.

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

### Footer artwork

The footer prints the event title by default, or a **client logo** instead —
Admin › Settings › Branding › Footer image, any PNG, JPEG or TIFF. It replaces
the text in all three layouts, including the stacked arrangement the duplicate
strip uses when it carries a QR code. The code itself always stays: it is
functional rather than decorative, and a guest who cannot scan it has lost their
photographs.

The file is **copied into Application Support**, not referenced where it was
found. A booth runs all evening off a laptop whose Desktop gets tidied and whose
USB sticks get pulled; a settings file pointing at `~/Downloads/logo-final-v3.png`
is a print that quietly loses its footer three hours in. Artwork is normalised to
PNG on import — transparency survives, and the renderer has one format to read —
and capped at 2400px, past which it is more resolution than a two-inch strip can
print. Each import gets a fresh file name so a replaced logo can never be served
from a cache. Artwork that has gone missing falls back to the title text rather
than failing the sheet.

Slots are computed from margin, gutter and footer settings, so changing those in
Admin reflows the print. Photos are centre-cropped to fill (or letterboxed if
`Fit` is chosen) — never stretched.

Which makes the **framing guide** worth having on the guest screen, not just the
console: the live view is drawn to *fit* the panel while the print *fills* each
slot, so the edges of what a guest can see do not survive. How much is at stake
depends on the layout — a 3:2 body on the 4 Photos layout keeps only 44% of the
frame's width. `FramingGuide` marks the surviving area with a dashed box, dims
what is going to be trimmed, and rules it in thirds to frame against. It appears
only while there is somebody to frame: on the idle screen when it is showing the
camera, and through the countdown and between shots — never over the shutter
flash, the photograph just taken, or the finish screen.

Its geometry is measured against the *displayed picture* rather than the view it
sits in. Those differ whenever the camera's shape differs from the screen's, so
measuring against the container would put the guide out by the width of the
letterbox. The console draws the same guide plainly — no scrim, no thirds — since
it is there to check the crop, not to frame anyone.

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
# photobooth-mac
# photobooth-mac
