import SwiftUI
import AppKit

/// The guest-facing screen, dressed as a 1990s camcorder viewfinder: black field,
/// live view behind a dot-matrix OSD, timecode top-left, tape status top-right and
/// the date stamp bottom-left. Nothing administrative is reachable from here.
struct PhotoboothScreen: View {
    @ObservedObject var c: BoothController
    @ObservedObject var live: LivePreviewSource
    @ObservedObject private var clock = OSDClock.shared

    var body: some View {
        BoothStage(background: VHS.black) { size in
            let m = StageMetrics(size: size)
            ZStack {
                VHS.black

                // The picture sits behind the overlay, as it does in a viewfinder.
                ViewfinderImage(c: c, live: live, m: m)

                // Only while there is someone to frame: not over the shutter
                // flash, the photograph just taken, or the finish screen.
                if c.settings.framingGuide, showsFramingGuide, let frame = live.frame {
                    FramingGuide(imageAspect: frame.size.width / max(1, frame.size.height),
                                 cellAspect: LayoutRenderer.cellAspect(for: c.settings.layout,
                                                                      settings: c.settings,
                                                                      template: c.activeTemplate),
                                 cropMode: c.settings.cropMode,
                                 tint: Color(hex: c.settings.accentHex),
                                 lineWidth: max(1, m.pt(0.25)))
                }

                OSDLayer(c: c, live: live, m: m, now: clock.now)

                // Dressing stays out of the way of somebody trying to stand in
                // the right place: over a live picture the scanlines and the
                // vignette drop to a suggestion of themselves.
                CRTOverlay(scanlineSpacing: max(2, m.pt(0.30)),
                           scanlineOpacity: framingNow ? 0.07 : 0.22,
                           vignetteStrength: framingNow ? 0.20 : 0.55)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .animation(.easeInOut(duration: 0.22), value: c.state)
        }
        .background(VHS.black)
        .environment(\.vhsLightRendering, c.settings.lightRendering)
    }

    /// Somebody is looking at themselves right now, and can still move.
    private var framingNow: Bool { showsFramingGuide && live.frame != nil }

    /// States where the guest is looking at themselves and can still move.
    private var showsFramingGuide: Bool {
        switch c.state {
        case .idle:
            // Only when the idle screen is actually showing the camera.
            return c.settings.idleLiveView
        case .starting, .countdown, .interval, .retaking:
            return true
        case .capturing, .photoPreview, .generatingPrint, .printing, .complete, .failed:
            return false
        }
    }
}

// MARK: - Picture

private struct ViewfinderImage: View {
    @ObservedObject var c: BoothController
    @ObservedObject var live: LivePreviewSource
    let m: StageMetrics

    var body: some View {
        ZStack {
            switch c.state {
            case .idle:
                // Guests see themselves while they decide — the booth reads as a
                // mirror rather than a black screen. Falls back to the empty
                // field when the camera has nothing to give.
                if c.settings.idleLiveView, let frame = live.frame {
                    picture(frame)
                } else {
                    VHS.field
                }
            case .photoPreview:
                if let shot = c.shotPreview {
                    Image(nsImage: shot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .transition(.opacity)
                } else {
                    VHS.field
                }
            case .capturing:
                // Shutter: the tape-era white flash.
                Color.white
            case .complete:
                // The finish screen composes the print and the QR card together,
                // so the picture is drawn there rather than here.
                VHS.field
            default:
                if let frame = live.frame {
                    picture(frame)
                } else {
                    VHS.field
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The camera's own picture, lifted for the room.
    ///
    /// A booth stands in the dark corner and the camera is exposed for its
    /// flash, so the live picture can be far darker than the photograph that
    /// comes out of it — and a guest who cannot see themselves cannot frame
    /// themselves. The lift is on the screen alone: the file, the print and the
    /// camera's own settings are untouched. Contrast comes up with brightness
    /// because lifting brightness by itself only greys the picture.
    @ViewBuilder
    private func picture(_ frame: NSImage) -> some View {
        let lift = min(max(c.settings.previewBrightness, 0), 0.5)
        Image(nsImage: frame)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .scaleEffect(x: c.settings.mirrorImages ? -1 : 1, y: 1)
            .brightness(lift)
            .contrast(1 + lift * 0.5)
            .saturation(lift > 0 ? 1 : 0.92)
    }
}

// MARK: - OSD

private struct OSDLayer: View {
    @ObservedObject var c: BoothController
    @ObservedObject var live: LivePreviewSource
    let m: StageMetrics
    let now: Date

    var body: some View {
        ZStack {
            centrepiece

            VStack(spacing: 0) {
                topRow
                Spacer(minLength: 0)
                bottomRow
            }
            .padding(m.pt(4))
        }
    }

    // MARK: Top strip — recording state and shot counter

    private var topRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: m.pt(0.8)) {
                HStack(spacing: m.pt(1.1)) {
                    CaptureLamp(size: m.pt(1.5), active: c.state.isSessionActive)
                    VHSText(text: modeWord, size: m.pt(2.2))
                }
                VHSText(text: VHS.timecode(c.sessionElapsed), size: m.pt(2.2), color: VHS.phosphor)
                if c.settings.cameraBackend.isSimulated {
                    VHSText(text: "▲ DEMO — NO CAMERA", size: m.pt(1.6), color: VHS.amber)
                }
            }

            Spacer(minLength: m.pt(4))

            VStack(alignment: .trailing, spacing: m.pt(0.8)) {
                if let p = c.progress {
                    VHSText(text: "PHOTO \(p.shot)/\(p.total)", size: m.pt(2.2))
                } else {
                    VHSText(text: "\(c.shotCount) SHOT", size: m.pt(2.2))
                }
                VHSText(text: layoutTag, size: m.pt(1.7), color: VHS.dim)
            }
        }
    }

    private var modeWord: String {
        // A retake keeps saying RETAKE right through its countdown and capture,
        // so the guests know which photo they are doing again.
        if c.retakingShot != nil, c.state.isSessionActive { return "RETAKE" }
        switch c.state {
        case .idle:            return "CAPTURE MODE"
        case .starting:        return "CAPTURING"
        case .countdown:       return "CAPTURING"
        case .capturing:       return "CAPTURING"
        case .photoPreview:    return "REVIEW"
        case .interval:        return "CAPTURING"
        case .retaking:        return "RETAKE"
        case .generatingPrint: return "PROCESS"
        case .printing:        return "PRINT"
        case .complete:        return "PLAY ▶"
        case .failed:          return "ERROR"
        }
    }

    private var layoutTag: String {
        // A saved layout is what is actually being printed, so it is what the
        // corner should say — not the built-in it happens to sit in front of.
        if let t = c.activeTemplate, !t.name.isEmpty {
            return String(t.name.prefix(14))
        }
        switch c.settings.layout {
        case .duplicateStrips: return "STRIP ×2"
        case .eightUnique:     return "8 UNIQUE"
        case .fourFullPage:    return "FULL PAGE"
        }
    }

    // MARK: Bottom strip — clock, date stamp, tape status

    private var bottomRow: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: m.pt(0.6)) {
                VHSText(text: VHS.clock(now), size: m.pt(2.6))
                VHSText(text: VHS.dateStamp(now), size: m.pt(2.6))
            }

            Spacer(minLength: m.pt(4))

            VStack(alignment: .trailing, spacing: m.pt(0.9)) {
                VHSText(text: eventTag, size: m.pt(1.9), color: VHS.dim)
                HStack(spacing: m.pt(1.4)) {
                    VHSText(text: "SP", size: m.pt(1.7), color: VHS.dim)
                    TapeGauge(filled: tapeBars, size: m.pt(1.7))
                }
            }
        }
    }

    private var eventTag: String {
        c.activeEvent?.name ?? c.settings.eventTitle
    }

    /// Bars fall as the session progresses, like tape running out.
    private var tapeBars: Int {
        guard let p = c.progress else { return 4 }
        let left = Double(p.total - p.shot + 1) / Double(max(1, p.total))
        return max(1, Int(ceil(left * 4)))
    }

    // MARK: Centre — whatever the guest needs to look at right now

    @ViewBuilder
    private var centrepiece: some View {
        switch c.state {
        case .idle:
            IdleCentre(c: c, live: live, m: m)

        case .starting:
            OSDBanner(m: m, lines: ["GET READY"], tint: VHS.phosphor)

        case .countdown(let shot, _, let remaining):
            CountdownCentre(m: m, value: remaining,
                            label: c.retakingShot == shot ? "● RETAKE \(shot)" : "● CAPTURING",
                            tint: c.retakingShot == shot ? VHS.amber : VHS.rec)

        case .capturing:
            Text("")   // the white flash is the whole frame

        case .photoPreview(let shot, _):
            VStack {
                Spacer()
                framedTag(c.retakingShot == shot ? "PHOTO \(shot) REPLACED" : "PHOTO STORED",
                          tint: VHS.phosphor)
                    .padding(.bottom, m.pt(10))
            }

        case .interval:
            OSDBanner(m: m, lines: ["STAND BY", "NEXT SHOT"], tint: VHS.phosphor)

        case .retaking(let shot, _):
            OSDBanner(m: m, lines: ["RETAKE \(shot)", "ONE MORE — GET READY"], tint: VHS.amber)

        case .generatingPrint:
            OSDBanner(m: m, lines: ["PROCESSING", "▮▮▮▮▮▯▯▯"], tint: VHS.phosphor)

        case .printing:
            OSDBanner(m: m, lines: ["PRINTING", "PLEASE WAIT"], tint: VHS.phosphor)

        case .complete:
            CompleteCentre(c: c, m: m)

        case .failed(let reason):
            OSDBanner(m: m, lines: ["--- ERROR ---", reason], tint: VHS.amber)
        }
    }

    private func framedTag(_ s: String, tint: Color) -> some View {
        VHSText(text: s, size: m.pt(2.4), color: tint)
            .padding(.horizontal, m.pt(2.4))
            .padding(.vertical, m.pt(1.2))
            .background(Color.black.opacity(0.55))
            .overlay(Rectangle().stroke(tint.opacity(0.7), lineWidth: max(1, m.pt(0.18))))
    }
}

// MARK: - Idle

private struct IdleCentre: View {
    @Environment(\.vhsLightRendering) private var light
    @ObservedObject var c: BoothController
    @ObservedObject var live: LivePreviewSource
    let m: StageMetrics
    @State private var blink = true

    var body: some View {
        let ready = c.cameraState.isReady && c.activeEvent != nil
        let overPicture = c.settings.idleLiveView && live.frame != nil
        let idleLogo = IdleLogoCache.image(for: c.settings.idleLogoFile)

        VStack(spacing: m.pt(3)) {
            // The operator's own mark when they have one, the event's name when
            // they have not. Drawn at its own proportions — a wordmark stretched
            // to a box is somebody's brand ruined — and never larger than the
            // width they asked for.
            if let logo = idleLogo {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: m.size.width * CGFloat(min(max(c.settings.idleLogoWidth, 0.1), 0.9)))
                    .opacity(overPicture ? 0.95 : 0.85)
                    .accessibilityLabel(c.settings.eventTitle)
            } else {
                VHSText(text: c.settings.eventTitle, size: m.pt(3.4),
                        color: overPicture ? VHS.phosphor.opacity(0.9) : VHS.dim, tracking: 0.34)
            }

            Button(action: { c.startSession() }) {
                VStack(spacing: m.pt(2)) {
                    VHSText(text: c.settings.idleHeadline,
                            size: m.pt(5.6),
                            color: ready ? VHS.phosphor : VHS.dim)
                        .multilineTextAlignment(.center)

                    HStack(spacing: m.pt(1.4)) {
                        CaptureLamp(size: m.pt(1.8), active: ready)
                        VHSText(text: ready ? "PRESS TO CAPTURE" : "CAMERA NOT READY",
                                size: m.pt(2.0),
                                color: ready ? VHS.rec : VHS.amber)
                    }
                }
                .padding(.horizontal, m.pt(7))
                .padding(.vertical, m.pt(4.5))
                .overlay(CornerBrackets(color: ready ? VHS.phosphor : VHS.dim,
                                        length: m.pt(4),
                                        thickness: max(1.5, m.pt(0.28))))
                .opacity(ready && !blink ? 0.82 : 1)
            }
            .buttonStyle(.plain)
            .disabled(!ready)

            VHSText(text: c.settings.idleSubhead, size: m.pt(2.0), color: VHS.dim)

            if !ready {
                VHSText(text: c.activeEvent == nil ? "NO EVENT SELECTED — ASK A HOST"
                                                   : "PLEASE ASK A HOST",
                        size: m.pt(1.8), color: VHS.amber)
                    .padding(.top, m.pt(1))
            }
        }
        .padding(m.pt(6))
        // No scrim over the picture. A wash dark enough to carry the words also
        // hides the middle of the frame — exactly where the guest is standing —
        // so the words carry themselves instead: a tight shadow around the
        // glyphs, which costs the picture nothing but the strokes' own width.
        .shadow(color: .black.opacity(overPicture ? 0.9 : 0), radius: m.pt(0.5))
        .shadow(color: .black.opacity(overPicture ? 0.55 : 0), radius: m.pt(2.4))
        .onAppear {
            guard !light else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { blink = false }
        }
    }
}

/// The imported mark, read once per appearance rather than per frame — the idle
/// screen redraws on a blink timer, and a file read on each pass would be a disk
/// hit every second for an entire evening.
private struct IdleLogoCache {
    static var name: String = ""
    static var image: NSImage?

    static func image(for fileName: String) -> NSImage? {
        if fileName == name { return image }
        name = fileName
        image = BrandingAssets.url(for: fileName).flatMap { NSImage(contentsOf: $0) }
        return image
    }
}

// MARK: - Countdown

private struct CountdownCentre: View {
    let m: StageMetrics
    let value: Int
    var label: String = "● CAPTURING"
    var tint: Color = VHS.rec

    var body: some View {
        ZStack {
            Color.black.opacity(0.30)
            VStack(spacing: m.pt(1.5)) {
                VHSText(text: "\(value)", size: m.pt(30), tracking: 0)
                    .id(value)
                    .transition(.opacity)
                VHSText(text: label, size: m.pt(2.2), color: tint)
            }
        }
        .animation(.easeOut(duration: 0.16), value: value)
    }
}

// MARK: - Banner

private struct OSDBanner: View {
    let m: StageMetrics
    let lines: [String]
    let tint: Color

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: m.pt(1.6)) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    VHSText(text: line,
                            size: i == 0 ? m.pt(5.0) : m.pt(2.4),
                            color: i == 0 ? tint : VHS.dim)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: m.pt(80))
                }
            }
        }
    }
}

// MARK: - Complete

private struct CompleteCentre: View {
    @Environment(\.vhsLightRendering) private var light
    @ObservedObject var c: BoothController
    let m: StageMetrics
    @State private var blink = true

    private struct QRCard { let image: NSImage; let caption: String }

    private var qrCards: [QRCard] {
        var out: [QRCard] = []
        if let qr = c.sessionQRImage { out.append(QRCard(image: qr, caption: c.settings.qrCaption)) }
        if let qr = c.brandQRImage { out.append(QRCard(image: qr, caption: c.settings.customQRCaption)) }
        return out
    }

    var body: some View {
        VStack(spacing: m.pt(2.2)) {
            HStack(alignment: .center, spacing: m.pt(3.5)) {
                if let print = c.sessionPrintImage {
                    Image(nsImage: print)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    VHSText(text: "SAVED", size: m.pt(4), color: VHS.dim)
                        .frame(maxWidth: .infinity)
                }

                // The loop, so guests can see there is one to take before they
                // ever scan the code. Given its own fixed column for the same
                // reason as the QR cards: the print keeps whatever is left.
                if GIFRenderer.enabled, let gif = c.sessionGIF {
                    VStack(spacing: m.pt(1.1)) {
                        AnimatedImage(image: gif, animates: !light)
                            .aspectRatio(gif.size.width / max(1, gif.size.height),
                                         contentMode: .fit)
                        VHSText(text: "YOUR GIF", size: m.pt(1.7), color: VHS.dim)
                    }
                    .frame(width: m.pt(20))
                }

                // One card or two, depending on what the operator asked the code
                // to point at. Two are stacked and narrowed rather than set side
                // by side, so the print keeps the width it needs.
                let cards = qrCards
                if !c.photoQRs.isEmpty {
                    // One code per photograph, after the ones for the whole
                    // session: each guest in a group scans the shot they are in.
                    // The long "scan to get your photos" caption does not fit a
                    // grid tile; beside PHOTO 1, 2, 3, "ALL PHOTOS" says it.
                    PhotoQRGrid(tiles: (c.sessionQRImage.map { [("ALL PHOTOS", $0)] } ?? [])
                                    + (c.brandQRImage.map { [(c.settings.customQRCaption, $0)] } ?? [])
                                    + c.photoQRs.map { ("PHOTO \($0.id)", $0.image) },
                                m: m)
                } else if !cards.isEmpty {
                    VStack(spacing: m.pt(2)) {
                        ForEach(cards, id: \.caption) { card in
                            QRPanel(image: card.image, caption: card.caption, m: m)
                        }
                    }
                    .frame(width: m.pt(cards.count > 1 ? 21 : 25))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .padding(.horizontal, m.pt(5))
        .padding(.top, m.pt(11))
        // Clears the clock, date stamp and tape gauge along the bottom edge.
        .padding(.bottom, m.pt(10))
        .onAppear {
            guard !light else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { blink = false }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if c.awaitingContinue {
            HStack(spacing: m.pt(1.4)) {
                CaptureLamp(size: m.pt(1.6), active: true)
                // The press does both jobs when a print is waiting, so it says so.
                VHSText(text: c.pendingPrint ? "PUSH BUTTON TO RESTART AND PRINT"
                                             : "PUSH BUTTON TO RESTART",
                        size: m.pt(2.0), color: VHS.rec)
            }
            .padding(.horizontal, m.pt(3))
            .padding(.vertical, m.pt(1.3))
            .background(Color.black.opacity(0.85))
            .opacity(blink ? 1 : 0.55)
        } else {
            VHSText(text: c.settings.autoPrint ? "ALL DONE — COLLECT YOUR PRINT" : "ALL DONE",
                    size: m.pt(2.4), color: VHS.phosphor)
                .padding(.horizontal, m.pt(3))
                .padding(.vertical, m.pt(1.3))
                .background(Color.black.opacity(0.85))
        }
    }
}

// MARK: - QR card

/// The handout card: a white QR panel the guests photograph with their phones.
///
/// Drawn white on black and without interpolation — a smoothed or tinted QR is
/// the usual reason a phone camera sits there refusing to read one.
/// Codes laid out as a grid, sized so each stays scannable across a room.
///
/// A QR code needs about 20mm on a phone's view before it reads reliably. On the
/// 32" 1080p panel this booth runs at, a tile of 12 stage units comes out near
/// 70mm, so three across leaves plenty in hand even from a couple of metres.
private struct PhotoQRGrid: View {
    let tiles: [(label: String, image: NSImage)]
    let m: StageMetrics

    var body: some View {
        let cols = tiles.count <= 4 ? 2 : (tiles.count <= 9 ? 3 : 4)
        let side = m.pt(cols == 2 ? 15 : (cols == 3 ? 12 : 9.5))
        let grid = Array(repeating: GridItem(.fixed(side), spacing: m.pt(1.4)), count: cols)

        LazyVGrid(columns: grid, spacing: m.pt(1.2)) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, t in
                VStack(spacing: m.pt(0.5)) {
                    Image(nsImage: t.image)
                        .resizable()
                        .interpolation(.none)     // a smoothed QR is an unreadable one
                        .aspectRatio(1, contentMode: .fit)
                        .padding(m.pt(0.6))
                        .background(Color.white)
                    VHSText(text: t.label, size: m.pt(1.15), color: VHS.phosphor,
                            tracking: 0.12, fringe: 0)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: side)
            }
        }
        .padding(m.pt(1.2))
        .background(Color.black.opacity(0.75))
        .overlay(Rectangle().stroke(VHS.phosphor.opacity(0.55), lineWidth: max(1, m.pt(0.18)))
            .allowsHitTesting(false))
        .fixedSize()
    }
}

private struct QRPanel: View {
    let image: NSImage
    let caption: String
    let m: StageMetrics

    var body: some View {
        VStack(spacing: m.pt(1.3)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(1, contentMode: .fit)
                .padding(m.pt(1.1))
                .background(Color.white)

            VHSText(text: caption, size: m.pt(1.5), color: VHS.phosphor, tracking: 0.12, fringe: 0)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(m.pt(1.5))
        .background(Color.black.opacity(0.75))
        .overlay(Rectangle().stroke(VHS.phosphor.opacity(0.55), lineWidth: max(1, m.pt(0.18))))
    }
}
