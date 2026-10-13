# Photobooth

A native macOS photobooth for live events: Canon EOS DSLR over USB, Canon SELPHY
CP1500 for borderless 4×6 prints, a guest screen and an operator console as two
independent windows.

Built with Swift + SwiftUI. No Xcode project — `build.sh` drives `swiftc` and
`clang` directly, and produces a self-contained `.app` and `.dmg`.

## Features

**Capture** — Canon EOS DSLR over USB through libgphoto2, needing no Canon SDK
licence; a UVC webcam; or a generated demo source that badges itself so it cannot
be left selected by mistake. Live view runs throughout, and a **framing guide** on
the guest screen marks what the print will keep, dims what it will trim and rules
it in thirds, so nobody finds themselves cropped out of the 4×6.

**Print** — borderless 4×6 on a Canon SELPHY CP1500 through the macOS print
system. Three built-in layouts, 1–10 copies, margins and gutters that reflow the
sheet as they change, and an optional **client logo** in the footer. A QR code on
the print or the finish screen hands guests their photographs.

**Print layout editor** — a window of its own for arranging a sheet: drag
photograph slots where you want them, lay logos and stickers over or behind the
photographs, frame the lot with a border, and put the guest code where it suits.
**A layout belongs to an event**, so a wedding and the corporate night after it
print completely different sheets with nothing switched over between them.

**Camera settings from the console** — ISO, aperture, shutter speed, white
balance and the rest of the Canon's own settings are read from the body and can
be changed in the admin, without touching the camera.

**Print counter** — the Event card counts **sheets** rather than sessions, since
copies are what empties a paper cartridge: a session set to two copies takes two
out of the pack. A sheet counts as printed only once CUPS says the job finished —
the job is watched and carried back onto the session record, so "printed" means
one came out rather than one was handed to the print system. Anything still
queued or failed is shown beside the total.

**Events** — every session belongs to one client booking, so a night's
photographs stay segregated on disk rather than piling into one folder. Sessions
cannot start without an event selected, and the Start button carries the client's
name.

**Turned slots and stickers** — anything on a print layout can be set at an
angle, by dragging its handle or typing the degrees, against a grid and rulers
that snap.

**A printed cutting line** — a faint dotted line down the middle of a sheet that
holds two strips, so they can be cut apart cleanly.

**Event tracker and PDF report** — clients, photographs, sheets and cost as the
night goes on, exported as a one-page report for the client or the accounts.

**Quick tab** — the four controls an operator needs during an event, at thumb
size, for running the booth from a phone.

**Dry run** — rehearse a whole evening from the console: real camera, real
uploads, every layout in turn, and no paper.

**One guest, one session** — a session page no longer opens onto the whole
event's album unless the operator asks for it.

**Photographs with no internet** — the booth serves them off its own disk over
the venue's wifi, with a *join wifi* code on the finish screen; the printed code
still points at the permanent online page.

**A film of every session** — the live view, the shutters and each photograph as
it was taken, ending on the booth's logo: an MP4 a guest can post straight to
Instagram or TikTok.

**A GIF for every session** — each photograph filling a page in the print's own
branding, saved beside the photographs, uploaded with them, and carrying its own
QR code on the finish screen so a guest can take it away there and then.

**A print counter per event** — sheets actually out of the printer, with anything
still queued or failed beside it.

**Session pages and per-photo codes** — every session gets its own webpage,
styled after Glyphy, with its link in the admin; every photograph gets its own code
on the finish screen. Photographs live on Cloudinary, the pages on GitHub Pages.

**Gallery** — GitHub Pages, Cloudinary or a self-hosted site, with
**password-protected album pages** whose contents are encrypted rather than merely
hidden: a page found without its password does not know where any photographs
are. The upload queue is written to disk immediately and drains whenever the site
is next reachable, which may be three days later.

**Guest screen** — a 1990s camcorder viewfinder that fills any display, with a
**light-rendering** mode for a booth screen carried over USB, wireless or screen
sharing, where an idle booth then produces no frames at all.

**Operator console** — navigation down a left rail, print layout and copies first
because they are what changes between groups, and **touch sizing one tap away** in
the rail for a console running on a touch panel.

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

**Camera settings** — Settings → *Camera Settings* reads ISO, aperture, shutter
speed, exposure compensation, white balance, image format and the rest straight
off the body through `gp_camera_get_single_config`, and writes a change back the
same way. Nothing is stored in the booth's settings file: the camera holds these,
and the card only ever shows what it last reported. Settings the body decides for
itself — shutter speed with the dial on Av, or anything at all in a fully
automatic mode — are shown as plain text and cannot be picked, because setting
them would be ignored. A write is refused during a session, and the whole list is
re-read after every change, since on a Canon the exposure settings move together.

**Not every PTP device is a camera.** This booth drives its guest screen from an
iPad over USB, and an iPad answers PTP well enough that libgphoto2 lists it,
opens it, and then refuses every preview and capture with *Unsupported
operation* — a booth connected to a tablet, reporting a camera that cannot take
a photograph. The shim now picks the first device on the bus that is not an
Apple one and binds to that model and port explicitly, rather than letting
`gp_camera_init` open whatever answers first; if nothing on the bus qualifies it
says so instead of connecting to something useless.

**A refused shutter.** A Canon EOS reports almost everything it will not do as
`Unspecified error`, and the booth was seeing it on every capture while connect
and live view worked perfectly. Three defences, in the order they matter:

* **Live view goes down for the duration of the shot.** An EOS holding the
  mirror up for the preview will not release the shutter; the `viewfinder`
  setting is switched off before the capture and back on after.
* **A second way to fire.** If `gp_camera_capture` is still refused, the shim
  falls back to `gp_camera_trigger_capture` and waits for the body to announce
  the file — Canon bodies that reject the first often accept this, because it
  does not wait on the same autofocus confirmation. Stale events are drained
  first, since a session that failed halfway leaves them queued and the next
  capture is answered with one of those.
* **An error worth reading.** The failure now names the mode dial's position
  when the body will report it, because "the dial is on Auto" is the answer nine
  times in ten, and says what else to check — focus, card, battery.

**Printer** — prints go through the macOS print system (CUPS) via `lp`, which
gives a trackable job id and access to the CP1500's `Postcard.Fullbleed` media.
No proprietary SELPHY protocol is implemented.

Two other camera sources exist behind the same `CameraBackendService` protocol:
a UVC/webcam backend, and a demo source that generates test frames. The demo
source paints a large orange **DEMO SOURCE** badge across the guest screen so it
cannot be left selected at an event by mistake. Its frames carry the operator's
own idle logo when one is set, so a booth being shown to a client — screen,
print, GIF and webpage — is their booth all the way through rather than a
stranger's test card; the badge is what keeps that honest.

## Layout

```
Sources/
  main.swift              app entry, two NSWindows, menus, global key handling
  BoothController.swift   session state machine, service wiring
  CameraService.swift     CameraBackendService + DSLR / webcam / demo backends
  PrinterService.swift    CUPS discovery, status polling, job submission
  PhotoStorageService.swift  session tree, crash recovery, disk preflight
  LayoutRenderer.swift    4×6 geometry and drawing, EXIF orientation, mirroring
  PrintTemplate.swift     operator-arranged sheets, and their store
  PrintEditor.swift       the layout editor window
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

**The dressing gives way to the picture.** Whenever somebody is on screen and
can still move — the idle screen showing the camera, the countdown, between shots
— the scanlines and vignette drop to a suggestion of themselves, and the idle
words carry a tight shadow instead of the black wash that used to sit behind
them. A wash dark enough to hold the lettering also hides the middle of the
frame, which is exactly where the guest is standing.

**Preview brightness** (Settings → Camera Advanced) lifts the live picture on the
guest screen, 0–50%, with contrast following it so the lift does not just grey
the picture. A booth stands in the darkest corner of the room while the camera is
exposed for its flash, so what a guest sees while framing can be far darker than
the photograph that comes out. The lift is on that screen alone: the file, the
print, the console's own preview and the camera's settings are untouched.

**An idle logo** can stand in for the event title on the guest screen: imported
through Settings → Branding, copied into the app's own folder like the footer
artwork, and drawn at its own proportions to whatever share of the screen width
the operator sets. The idle screen is black or a live picture, so pale artwork on
a transparent background is what suits it. Without one, the event title is shown
as before.

The guest viewfinder carries the OSD a camcorder would — `● REC` and a running
timecode top-left, shot counter and layout top-right, `18:43 / 21.08.2026 FRI`
bottom-left, event name and an `SP` tape gauge bottom-right that empties as the
session runs.

macOS ships no dot-matrix face, so the character is **built rather than set**:
heavy monospaced glyphs at wide tracking, a red/cyan split behind the white and a
little bloom (`VHSText`). Nothing to license, nothing to bundle.

**The console does not follow the booth.** Guests look at a black viewfinder;
the operator looks at a bright panel, and the two have never needed to match.
The console is built to shadcn/ui's tokens — "clinical blueprint on frosted
paper": a three-tone monochrome surface stack (canvas `#f5f5f5` → surface-alt
`#fafafa` → paper `#ffffff`), ink `#0a0a0a` type, mid-gray `#737373` for helper
copy, hairline `#e5e5e5` edges, and a single ember `#e7000b` kept for
destruction. Cards are paper at 24pt corners with 20pt padding; anything
interactive is a pill.

Three deliberate departures from that reference:

- **Buttons are capsules, not a flat 18pt radius.** 18pt on the reference's 36pt
  button *is* a pill, and pill geometry is what the system actually asks for.
  These run 44–60pt for touch, where a fixed 18 would read as a rounded box.
- **No card shadow.** The system stacks three; that is an offscreen pass per card
  on every redraw, which this console was stripped of once already and which a
  screen carried over USB pays for twice. The hairline defines the edge, which
  the system says it must do anyway.
- **Status stays chromatic.** The palette is monochrome and reserves red for
  destructive actions, but an operator has to read "camera gone" across a dark
  room at a glance, and a grey dot cannot say it. The status hues are darkened
  until they hold contrast on paper.

Geist is not on macOS, so the system font stands in for it; small uppercase
captions keep the monospaced treatment they had.

`VHSText` still has a flat path (`fringe: 0`) that renders one `Text` instead of
three plus two blurs and a shadow, and the console's captions use `OSDLabel`,
which is just capitals with tracking.

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

**Touch controls** sizes the console for a fingertip. The switch sits in the
sidebar above Open Booth, showing its own state — it is the difference between a
console you can use with a finger and one you cannot, and somebody setting a
booth up on a touch panel has no reason to go hunting through Settings for it.

It cannot be detected and is deliberately a preference: an iPad driven as a
monitor delivers its taps to macOS as ordinary mouse clicks, indistinguishable
from a trackpad, so there is nothing for the app to sense.

The target is Apple's 44pt minimum, which on an 11" iPad at 2× is about 8.5mm of
glass — the physical size that number was chosen for on iOS. Measured down the
Session column at 1180 × 820:

| | off | on |
| --- | --- | --- |
| Start Session | 31 pt | 60 pt |
| Restart / Print Session | 28 | 54 |
| Retake number | 29 | 60 × 56 |
| Copies | field + 11pt arrows | 56 × 56 buttons |
| Rail row | — | 58 |

The one thing that will not move is AppKit's own: a pop-up button or text field
tops out near 36pt even at `.extraLarge`, because those are drawn by the system
rather than by this app. Replacing them with custom controls is the only way past
it, and has not been done.

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

## The session film

Every session also produces `session.mp4`: the live view as it ran, the shutter
as a white flash, each photograph held as it was taken, and the booth's own logo
on the end. It is the thing a guest actually posts — a GIF is a loop, this is the
visit.

**Encoded as it happens.** A two-minute session at fifteen frames a second is
eighteen hundred frames; holding them to encode at the end would be gigabytes of
pixels and a wait the next group would feel. Frames go into an `AVAssetWriter` as
they arrive, on their own queue, and the file is closed moments after the last
shot — before the print is even composed.

**H.264 in an MP4**, because posting it is the whole point: Instagram, TikTok,
WhatsApp and Messages all take that with nothing asked of the phone. A typical
four-shot session is around 1.5 MB at 720 px.

**Timestamps come from the wall clock**, not a frame counter. The preview
stutters and stops dead during each capture while the mirror is up; counting
frames would quietly speed those gaps up until the clip no longer matched what
happened in the booth. A held photograph is written as two frames — one at each
end of its span — rather than sixty identical ones.

It travels with everything else: saved beside the photographs, uploaded to
Cloudinary's video endpoint (its own, separate from images), embedded at the top
of the session page with `playsinline` so an iPhone does not seize the screen,
and carrying its own QR code on the finish screen. Served from the Mac it needs
HTTP range requests — Safari asks for a slice before it will start a video and
gives up on a plain 200 — so the local server answers `206 Partial Content`.

A session that is cancelled or fails throws its recording away rather than
leaving half a file behind.

## The GIF

Every session also produces `session.gif`: **each photograph in turn, filling a
page in the sheet's own branding** — the same background, border, footer and
logos as the print, so the loop plainly came from the same booth as the strip in
the guest's hand. One frame per photograph, held 0.8s by default, looping for
ever.

A whole page rather than the printed strip. The print is the same picture twice,
or six small ones; at the size a GIF is watched on a phone that leaves every face
a thumbnail. `LayoutRenderer.compositeFullPage` collapses the sheet's photograph
slots into their own union and gives one photograph all of it, keeping everything
else exactly where the sheet puts it — so a logo placed clear of the pictures is
still clear of them.

It is built from the photographs, not from live view. Stills are what a session
always has, whatever the camera was doing between shots and whether or not live
view was even running, so the loop is never the thing that fails. (An earlier
version animated the seconds before each shutter from the preview stream; it
depended on live view, held hundreds of megabytes of frames per session, and is
gone.)

The GIF's settings carry the print's geometry with `dpi` moved to match the
smaller canvas — margins and type are specified in inches, so without that a
quarter-inch margin becomes a third of a 320px sheet. The QR code is dropped: it
is unreadable at that size, and hard black-and-white detail is the most expensive
thing a 256-colour format can carry, repeated in every frame.

One frame per photograph keeps it small. Measured on photographic content, an
eight-shot session:

| Long edge | File |
| --- | --- |
| 360 px | 0.4 – 0.6 MB |
| **480 px** (default) | **0.7 – 1.0 MB** |
| 640 px | 1.2 – 1.8 MB |

The GIF travels with the photographs everywhere they go — the session page, the
encrypted album, Cloudinary — and appears on the finish screen beside the print
so guests know there is one to take. **Its own QR code** sits with the others,
pointing straight at the GIF file rather than at the page around it: a guest who
wants the moving one wants it in their camera roll before they walk away, not
after two more taps. Under **light rendering** it is shown as a still: the finish
screen can be held for minutes, and a loop running that whole time is exactly the
perpetual redraw that mode exists to remove.

## Photographs over the venue's own wifi

A booth is very often somewhere with a network and no usable connection — a
marquee, a basement, a ballroom whose wifi is three bars of nothing. The
photographs are on this Mac the moment the shutter closes, so the only thing
between a guest and their pictures is a web server.

`LocalGalleryServer` is that server: it listens on every interface, and answers
three things and nothing else.

* `/s/<token>/` — the session page, the same design the web gets
* `/s/<token>/<file>` — one photograph, the print or the GIF
* `/` — the landing page, which lists nothing

Nothing is enumerable. A file is served only if it appears in that session's own
list of files, matched by name rather than looked up on disk, so no path can be
talked into leaving the folder; an unknown token is a 404. A booth on a venue's
wifi should hand a stranger nothing.

**Two codes, pointing at different places, on purpose.** The code on the *screen*
points at this Mac: instant, no upload to wait for, no internet needed. The code
*printed on the strip* keeps pointing at the permanent online page, because the
Mac's address dies when the booth is packed away — the upload queue publishes
that page the next time there is a connection. Per-photo codes and the GIF code
follow the screen's lead, which also means **individual photographs work offline
even with Originals switched off**, since they are on this disk either way.

**Joining the network is the step guests give up on**, so the finish screen can
carry a *join wifi* card: `WIFI:T:WPA;S:…;P:…;;`, which both iOS and Android read
straight from the camera and offer to act on. The operator types the network's
name and password once in Admin.

The address is re-read rather than remembered. DHCP hands out a different one at
every venue, and a booth carried into another room lands on another network, so
the five-second tick that watches for the camera watches the address too and
rebuilds the codes on screen when it changes. A fixed address can be pinned in
Admin for an operator who always brings the same router.

macOS will ask once for permission to accept incoming connections — the booth
cannot be reached until that is allowed.

## Getting the printed code working at once

GitHub Pages takes **twenty-odd seconds to build whatever is pushed to it**
(measured on this site: three seconds to push, twenty-three to build). For most
of a guest's first minute, a code printed on their strip would lead to a 404 —
and a guest who scans a fresh print and gets "not found" concludes the booth
lost their photographs.

So **the page is pushed when the session starts, not when it ends.** The session's
token is assigned when the folder is created, so its address is known before the
first shot: a holding page goes up immediately, GitHub builds it while the guests
are still posing, and the real page replaces it when the photographs land. The
holding page refreshes itself every ten seconds — somebody standing in a marquee
holding a strip will not pull-to-refresh on a promise — and it never overwrites a
page that already has photographs on it, so a retake cannot take a guest's
pictures away again. Git is serialised behind a lock, because the two pushes now
overlap by design.

**The upload queue no longer lets one session block the rest.** It had been
draining oldest-first and *breaking out of the loop* on the first failure, so ten
sessions from a previous event — all failing permanently, because they had no
print and originals were switched off — sat in front of every new session and
kept it waiting through their exponential backoff. Now:

* sessions are attempted **newest first**, since a guest at the booth is waiting
  and last weekend's backlog is not;
* a failure that can never succeed (**nothing to upload**, files deleted) drops
  out of the queue instead of failing for ever in front of everything else;
* one failure moves on to the next session; only two in a row stop the pass,
  which is what a dead network actually looks like.

## Who can see whose photographs

A session page used to end with **The whole album** — a band opening onto every
session of the night. Convenient for the client who booked the booth, and a
surprise for a guest at a corporate party who scans their strip and finds
everybody else's photographs.

**Gallery Site → "Link the whole album from each session page"** decides it, and
it is **off by default**: a guest sees their session and nothing else. The album
link does not disappear — it stays in the admin, which is where the operator
needs it, to send to whoever hired the booth. Turning it on says so plainly,
because the consequence is not obvious from the switch.

The local server never links the album whatever the setting says: it serves one
session at a time and has no album to serve.

None of this is privacy in the strong sense. Addresses are unguessable, which is
not the same as private, and anything published to a free GitHub Pages site is
world-readable to anyone holding the address.

## Session pages and per-photo codes

Every session gets its own webpage, and every photograph its own code on the
finish screen, so each guest in a group can take the shot they are in.

**Cloudinary will not serve a webpage.** Tested against a live account: an
uploaded HTML file comes back with `Content-Disposition: attachment`, so a guest
scanning its code gets a `page.html` download rather than a page. Images are a
different matter — they return `image/jpeg` with no such header and open straight
in the browser.

So the work is split by what each host will actually do. **Photographs go to
Cloudinary; each session's page goes to GitHub Pages** and loads its pictures from
Cloudinary by address. The repository holds a few kilobytes of HTML per session
rather than every photograph ever taken. Cloudinary answers with
`Access-Control-Allow-Origin: *`, so the page's download-all can still fetch the
images it zips — verified by fetching a Cloudinary image from a page on another
origin.

Set it up under **Gallery Site** with Cloudinary selected: the Cloudinary rows,
then *Session webpages* — the github.io address and the local clone. Leave the
page half empty and guests get the print image, as before. Uploads must be
switched on for any of this to reach the internet; the admin says so plainly when
they are off, because the links are built before anything uploads and look
correct whether or not the photographs ever arrive.

**Per-photo codes** point at the image itself, so they work on Cloudinary alone
with no page host at all. They follow the same rule as the session code: held
back until the photographs are online when *only show it once the photos are
online* is set, because a guest who scans too early gets an error and assumes the
booth is broken.

In the admin, **Session links** appear for the current session and for every past
one in the Sessions tab: the session link with its code, Copy and Open, a button
per photograph, and *Copy every photo link*.

Every page carries the operator's **logo across the header** — written once to
the site root and referenced from each page, because seventy pages carrying the
same picture is seventy copies of it. Without one, the site's name is set in type
instead. The local server answers for `/logo.png` the same way, so a page served
off the booth at a venue with no internet is branded too.

Every page also carries **one notice**, and it is the only thing on the page a
guest has to read rather than look at: *Save your photographs now — these are
deleted after two weeks.* On a session page it sits directly under the Save
buttons, where somebody decides whether to download; elsewhere it is at the foot.
The period comes from Gallery Site and nothing deletes anything on its own — it
is a promise the operator keeps, not a timer.

The pages are styled after **Glyphy** — "buttercream specimen sheet beneath
sunset bands": a warm cream canvas, a black nav strip, an oversized wordmark with
and colour only as full-bleed action bands stacked
yellow → orange → red → burgundy → plum. Cards use 14px corners and pills 28px;
nothing has a shadow. The reference's faces are not free to embed and the pages
are deliberately self-contained for venue wifi, so the heaviest system faces
stand in.

They are built for phones first: fluid type from a 320px iPhone SE up to a
desktop, gutters that clear the notch and home indicator, 44px-plus tap targets,
a smaller headline in landscape, and no sideways scrolling at any width.

**The wordmark is the point of this design on a laptop and the problem with it
on a handset.** At 17vw it ate the first screen, and a guest opening the page
came for their photographs, not for the typography. Below 430px everything steps
down together — heading, bands, pills, captions, gutters, card padding — so the
page keeps its proportions while the photographs come up the screen to meet the
thumb; below 360px it steps down again and the grid holds two per row, which is
what makes it read as a sheet rather than a list. The headline runs 35px on a
320px phone to 51px at 430, then back up its own curve to 150px on a desktop,
with nothing jumping at the breakpoint.

## What an event produced, and what it cost

The **Event Tracker** on the Control tab counts clients, photographs, sheets and
money as the night goes on, and **Export Report** writes it as a one-page PDF:
the figures, which layouts people took away and how many had each, then every
session in order — time, layout, photographs, copies, whether it printed.

Both are read from the session records every time rather than tallied as the
event runs. A second set of books can disagree with the first, and the records
are what the operator would check anyway. **A sheet counts only once CUPS says
the job finished**, so a queued or failed sheet is never billed to a client; the
cost is sheets × the price of paper and ink, which is how SELPHY packs are sold.

**The layout is stamped on the session when it is photographed**, not looked up
afterwards. An event's layout can be changed between groups, and a report that
renamed everybody's sheet retrospectively would be worse than no report at all.
Sessions shot before this keep working — they fall back to the event's layout,
and then to the built-in they were shot with.

## The Quick tab — running the booth from a phone

Admin assumes a mouse and a window: three columns of cards, hairlines,
eleven-point captions. None of it survives being driven with a thumb on a phone
over screen sharing, standing next to the booth.

**Quick** is the four things an operator touches during an event — copies,
layout, reprint, retake — at 56pt, which is a thumb. Layouts are listed **by
name**: a sketch of eight grey rectangles tells nobody which is which at arm's
length, and it halves how many fit on the screen. It is deliberately not a
responsive version of the Control tab; a layout that collapses gracefully still
shows everything, and everything is the problem.

## The dry run

A rehearsal of a whole evening, from the Control tab. It photographs imaginary
guests with whatever camera is connected, cycles through every layout — the
three built-ins and the operator's own — composes each sheet, builds the loop
and the film, publishes for real, and **prints nothing**.

It runs the booth's own session machinery rather than a copy of it. A rehearsal
that exercised a parallel code path would prove nothing about the one an event
uses: the point is to find what only breaks on the night — the USB link under
repeated capture, a layout that will not compose, the upload queue, the pages,
the codes.

Three things are changed for the duration and put back afterwards: the printer
is suppressed (`fakePrinting`, which also leaves the print counter alone, since
a sheet that never came out is not a sheet), the finish screen stops waiting for
a press, and everything lands in its **own "Dry run" event** so no client's
folder or album is filled with test shots. The event is created once, reused,
and safe to delete.

Uploads are real by default — that is most of what is being tested — and can be
switched off to rehearse somewhere with no signal.

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

## The print layout editor

The three built-in layouts compute their slots from the margin and gutter
settings, which keeps them tidy and makes them impossible to rearrange. A
template throws that away — every rectangle on the sheet is the operator's to
place. Open it from **Print Layout › Design a layout…** on the Control tab, or
⌘3.

What a template holds: photograph slots (several may show the *same* photograph,
which is how a strip gets printed twice), overlay images for logos and stickers
that sit either over or behind the photographs, a border, a background, and an
optional box for the guest QR code.

Saved layouts appear on the **Print Layout** card, each with a sketch of its own
slots. **They replace the three built-in ones there rather than sitting beneath
them**: the built-ins exist so a booth nobody has set up yet can still print
something, and the moment the operator has designed a layout of their own they
stop being a fallback and become three wrong answers above the right one. They
come back if every saved layout is removed. The same applies to the Quick tab and
the rehearsal's rota. A booth still standing on a built-in from before — which
would leave a list with nothing selected in it — moves to the first saved layout
when the card is next opened. Edit and Remove
sit on the tile — a layout is a thing the operator made, so managing it belongs
where it is chosen rather than behind another window. Removing one detaches it
from anything still pointing at it, so no booking is left referring to a layout
that has gone. **Save as new** keeps the original and adds a variant, which is
how a second layout usually comes about: somebody opens the one that works and
changes two things about it.

Every rectangle is stored as a **fraction of the canvas** rather than in inches
or pixels. Inches would have to be re-derived whenever the sheet changed;
fractions never do, so one template renders identically at 200, 300 or 600 DPI.
Templates live as one JSON file beside the settings — a few kilobytes, written
atomically, so a power cut mid-event cannot leave half a library behind.

**A saved layout also decides how many photographs to take.** Six slots showing
three photographs ask for three shots, not the eight the built-in layout behind
them would have wanted; a layout wanting eight gets eight even when the built-in
selection is four, which used to leave half the sheet printing grey numbered
placeholders. A run keeps the count it started with, so changing the layout
mid-session cannot move the goalposts on a guest halfway through.

Which layout a sheet uses is resolved fresh each time: **the event's own, then
the booth default, then the built-in layouts**. Deleting a template while it is
in use falls back rather than failing — a booth printing the wrong arrangement is
recoverable, one printing nothing is not.

Placement can be dragged, listed or typed. Anything selected carries **Across,
Down, Width and Height** as numbers, shown in **percent, pixels or inches** —
"37%", "440 px" and "1.6 in" are the kinds of thing somebody matching one slot to
another actually knows, and a slider cannot be told them. The values are only a
way of writing down the same stored fractions, so switching units changes nothing
about the sheet. Nudges are a percent, ten pixels or a twentieth of an inch; one
pixel at 300 DPI is a third of a millimetre, which nobody would see and everybody
would have to press forty times.

**An image can be inverted.** A logo drawn white for the booth's black screen is
invisible on white paper, and most operators have one file rather than two.
*Invert the colours* turns the artwork over — white becomes black — and leaves
transparency alone, so a mark on nothing stays a mark on nothing rather than
gaining a black box. The editor shows it inverted as it will print; the renderer
does the same thing with `CIColorInvert`, cached, since a proof, a GIF frame and
the real sheet all ask for the same picture.

**A sheet can carry more than one code.** *Add → QR code box* puts one down and
the button then offers another; each is selected, dragged, sized and removed on
its own. Two is the useful number: a sheet cut into strips leaves with two
different people, and a single code in the middle would be cut in half. Both
codes carry the same address — they are the same session.

A second box lands as the **mirror image of the first about the cutting line**,
so the pair sit the same distance in from each outside edge rather than on top
of one another, and *Match the other side* re-squares them after either is
moved. Codes are never turned, whichever one it is: the box exists to place the
code, not to tilt it.

A layout saved when there could only be one code opens with that code in place —
the old single box is folded into the list on read and never written again.

**Anything on the sheet can be turned.** Photo slots, logos and stickers carry
an angle in degrees clockwise about their own middle: drag the handle at the
top-left corner of whatever is selected, type the number, or take a quarter turn
either way. A drag settles on multiples of 15° when it comes within 3° of one, so
square and a deliberate tilt are both easy to hit and 7° is still available. The
guest code is the exception — it is placed but never turned, since a turned code
only makes a phone work harder.

The stored rectangle is always the *upright* one, so turning something never
moves it and straightening it needs no second nudge. The cost is that a turned
corner can hang past the edge of the paper, which the proof sheet shows honestly.
Drags are measured against the sheet rather than the item, because a turned item
has turned axes of its own and a drag read in those would send it off at the
angle it was pinned at; the resize handle does the opposite, reading the movement
back onto the item's own axes so width stays width.

**Guides, rulers and snapping.** A square grid taken from the sheet's short edge,
rulers down the top and left marked in whichever unit the placement fields are
showing — with the selected item's extent picked out on them — and snapping to
the grid, to the sheet's own middle, and to the edges and centres of everything
already on the page, which is what lines two slots up without either being typed.
Moving snaps by whichever of an item's three edges is nearest, so a box can be
aligned by its left, its middle or its right without being told which; resizing
snaps only the edge being dragged, so pulling a corner never shifts the opposite
one. The tolerance is a fraction of the sheet rather than screen points, so what
counts as near enough does not change when the window is resized. All three are
per-window preferences, not part of the layout: a grid is how somebody works, not
part of what they made.

**The cutting line** is the one guide that is printed. A faint dotted line down
(or across) the middle at the operator's own opacity and position, drawn over
everything except the guest code, so a sheet holding two strips can be cut apart
cleanly at a venue where the guillotine is a pair of scissors. Low opacity is the
trick: dark enough to follow under bad lighting, light enough that a millimetre
left on an edge does not read as a mistake. It never appears in the GIF, which is
never cut.

Two things the editor does deliberately:

- **The canvas is an approximation; the proof is not.** Dragging redraws on every
  frame, so the canvas is plain SwiftUI shapes. **Proof sheet** renders the
  genuine article through `LayoutRenderer.composite`, the same call the printer
  gets, with numbered stand-ins for the photographs.
- **Draw order is the grammar.** Background, overlays marked as sitting behind,
  photographs, the remaining overlays, border, code. That is what makes a sticker
  a sticker and a backdrop a backdrop.

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
