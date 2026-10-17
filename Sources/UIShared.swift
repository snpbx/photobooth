import SwiftUI
import AppKit

// MARK: - Palette

/// The Admin console's palette — shadcn/ui's tokens, "clinical blueprint on
/// frosted paper": a monochrome stack of three surfaces, ink type, and one red
/// kept for destruction.
///
/// The console only. The guest screen stays the 1990s camcorder it was: guests
/// look at a black viewfinder, operators at a bright panel, and the two have
/// never needed to match.
enum Palette {
    // Guest screen — unchanged.
    static let boothBG      = VHS.black
    static let boothBGLift  = VHS.field

    // Surfaces, lightest to darkest use.
    /// Page background, muted fills, secondary buttons.
    static let canvas       = Color(hex: "#F5F5F5")
    /// Card surfaces and popovers.
    static let paper        = Color(hex: "#FFFFFF")
    /// Sidebar, input resting state — one tonal step off the canvas, so the
    /// navigation reads as its own layer without needing a divider.
    static let surfaceAlt   = Color(hex: "#FAFAFA")

    // Ink.
    static let ink          = Color(hex: "#0A0A0A")
    static let inkSoft      = Color(hex: "#171717")
    static let midGray      = Color(hex: "#737373")
    static let hairline     = Color(hex: "#E5E5E5")

    /// Reserved for destruction. The only chromatic hue the system allows.
    static let ember        = Color(hex: "#E7000B")

    /// Status is the one place this console departs from the reference. The
    /// system is monochrome and keeps red for destructive actions only, but an
    /// operator has to read "camera gone" across a dark room in one glance, and
    /// a grey dot cannot say it. These are the reference's hues darkened until
    /// they hold contrast on paper.
    static let statusOK     = Color(hex: "#15803D")
    static let statusWarn   = Color(hex: "#A16207")
    static let statusBad    = Color(hex: "#E7000B")

    // Semantic aliases the console draws through.
    static let panel        = surfaceAlt
    static let card         = paper
    static let panelHead    = canvas
    static let text         = ink
    static let textDim      = midGray

    // Shape, from the reference: pills for anything interactive, 24 for cards.
    static let cardRadius: CGFloat   = 24
    static let nestedRadius: CGFloat = 10
    static let smallRadius: CGFloat  = 6
    static let cardPadding: CGFloat  = 20
}

// MARK: - Booth stage

/// Gives the guest layout the whole display, whatever shape it is.
///
/// This used to fit a 4:3 canvas and centre it, which pillarboxed a 16:9 panel —
/// on a 1080p screen that is 25% of the width spent on black. The stage now
/// takes every pixel the booth window has. What keeps that safe is
/// `StageMetrics`: the layout is still *authored* against a 4:3 reference, and
/// the metric stays pinned to it, so a wider screen buys room rather than
/// larger lettering.
struct BoothStage<Content: View>: View {
    var background: Color = Palette.boothBG
    @ViewBuilder var content: (CGSize) -> Content

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background.ignoresSafeArea()
                content(geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

/// Scales guest typography with the stage so the booth reads the same on a
/// 1024×768 booth panel and a 27" iMac.
struct StageMetrics {
    /// The canvas the guest screens are drawn against: 100 units across, 75
    /// down. Every `pt()` in `PhotoboothScreen` is a number on this grid.
    static let reference = CGSize(width: 100, height: 75)

    let size: CGSize

    /// One unit, taken from whichever axis is tighter.
    ///
    /// Deliberately *not* `size.width / 100`. Now that the stage fills a 16:9
    /// screen, width alone would make the unit a third larger while the height
    /// stayed put — every glyph and gutter would grow and the countdown digit
    /// would run off the top and bottom. Binding it to the tighter axis means a
    /// 4:3 panel is unchanged and a wide panel keeps the type it was designed
    /// with.
    var unit: CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(size.width / Self.reference.width, size.height / Self.reference.height)
    }

    func pt(_ u: CGFloat) -> CGFloat { u * unit }
}

/// Plays an animated GIF.
///
/// SwiftUI's `Image` draws one frame of a GIF and stops, so this drops to
/// `NSImageView`, which has animated them since long before SwiftUI existed.
///
/// Under light rendering it deliberately holds still. The finish screen can be
/// left up for minutes waiting for a press, and a loop running that whole time
/// is precisely the perpetual redraw that mode exists to remove — on a streamed
/// panel it would be the only thing on screen still costing bandwidth.
struct AnimatedImage: NSViewRepresentable {
    let image: NSImage
    var animates: Bool = true

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.imageFrameStyle = .none
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.image = image
        v.animates = animates
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        if v.image !== image { v.image = image }
        v.animates = animates
    }
}

// MARK: - Touch controls

private struct TouchControlsKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Size every control for a fingertip rather than a pointer.
    ///
    /// Set from a preference, never detected: an iPad driven as a monitor sends
    /// its touches to macOS as ordinary mouse clicks, indistinguishable from a
    /// trackpad. There is nothing for the app to sense, so the operator says so.
    ///
    /// The target is Apple's 44pt minimum. On an 11" iPad shown at 2× that is
    /// about 8.5mm of glass — the same physical size the number was chosen for
    /// on iOS in the first place.
    var touchControls: Bool {
        get { self[TouchControlsKey.self] }
        set { self[TouchControlsKey.self] = newValue }
    }
}

/// macOS draws `Toggle` as a 14pt checkbox, which is a quarter of the width a
/// finger can reliably hit. The switch style is nearer 50 × 30, so touch mode
/// swaps every toggle in the console for one in a single place.
struct TouchToggleStyling: ViewModifier {
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.toggleStyle(.switch)
        } else {
            content
        }
    }
}

// MARK: - Small building blocks

struct StatusDot: View {
    let tint: Color
    /// Kept for call-site clarity; the console draws a steady lamp either way.
    /// A repeating animation redraws its subtree at display rate for as long as
    /// the window is open, which is not a price worth paying for a blink.
    var pulsing: Bool = false

    var body: some View {
        Rectangle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .opacity(pulsing ? 0.85 : 1)
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    var accessory: AnyView? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.touchControls) private var touch

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                OSDLabel(text: title, size: 10, weight: .semibold, color: VHS.dim, tracking: 0.22)
                Spacer(minLength: 8)
                if let accessory { accessory }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(Palette.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: touch ? 20 : 13) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, touch ? 18 : 13)
        }
        // Paper on canvas, hairline edge, 24pt corners, 20pt padding — the
        // reference's card, minus its shadow stack. Three stacked shadows are an
        // offscreen pass per card on every redraw, which is the cost this
        // console was stripped of and which a screen carried over USB pays for
        // twice. The hairline alone defines the edge, which the system says it
        // must do anyway.
        .padding(touch ? Palette.cardPadding + 4 : Palette.cardPadding)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Palette.cardRadius, style: .continuous))
        // Decoration only: an overlay is drawn above the card's contents and
        // takes part in hit testing unless told not to.
        .overlay(RoundedRectangle(cornerRadius: Palette.cardRadius, style: .continuous)
            .stroke(Palette.hairline, lineWidth: 1)
            .allowsHitTesting(false))
    }
}

struct LabeledRow<Content: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.touchControls) private var touch

    var body: some View {
        VStack(alignment: .leading, spacing: touch ? 9 : 5) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 12)
                content()
            }
            if let help {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(VHS.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Renders an NSImage without SwiftUI's default resampling surprises.
struct ImageView: View {
    let image: NSImage?
    var contentMode: ContentMode = .fit
    var mirrored: Bool = false

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
        } else {
            Color.black.opacity(0.35)
        }
    }
}

struct LivePreview: View {
    let frame: NSImage?
    var mirrored: Bool
    var placeholder: String

    var body: some View {
        ZStack {
            Color.black
            if let frame {
                Image(nsImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 30, weight: .light))
                    Text(placeholder)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.45))
                .padding(20)
            }
        }
    }
}

/// Shows what the print will actually keep of what the camera can see.
///
/// The live view is drawn to *fit* the screen, but the print *fills* each slot,
/// so the sides — or the top and bottom — of what a guest can see are trimmed
/// away. Without a guide people frame themselves against the whole screen and
/// find themselves cropped on the 4×6.
///
/// The geometry is computed against the **displayed picture**, not the view it
/// sits in. Those are the same thing only when the camera's shape matches the
/// screen's; on a 3:2 body shown on a 16:9 panel the picture is letterboxed, and
/// measuring against the container would put the guide out by the width of the
/// bars. Mirroring needs no special handling — every part of this is symmetric
/// about the centre.
struct FramingGuide: View {
    /// Width ÷ height of the picture the camera is sending.
    let imageAspect: CGFloat
    /// Width ÷ height of one slot on the print.
    let cellAspect: CGFloat
    var cropMode: CropMode = .fill
    var tint: Color = VHS.amber
    var lineWidth: CGFloat = 2
    /// Darken what is going to be trimmed. A line on its own is ambiguous about
    /// which side of it you should be standing on.
    var dims = true
    /// How far down the trimmed edges go. Enough to read as "not this part",
    /// not so far that a guest at the edge of the frame disappears from their
    /// own screen while they are still deciding where to stand.
    var dimStrength: Double = 0.30
    /// Thirds inside the kept area, to frame against rather than just avoid.
    var thirds = true

    var body: some View {
        GeometryReader { geo in
            let b = geo.size
            let shown = Self.fit(aspect: imageAspect, in: b)
            let kept = Self.keptSize(shown: shown, cellAspect: cellAspect, cropMode: cropMode)
            let shownRect = Self.centred(shown, in: b)
            let keptRect = Self.centred(kept, in: b)

            ZStack {
                if dims, kept != shown {
                    // Even-odd fill leaves a hole where the picture survives.
                    Path { p in p.addRect(shownRect); p.addRect(keptRect) }
                        .fill(Color.black.opacity(dimStrength), style: FillStyle(eoFill: true))
                }
                if thirds {
                    Path { p in
                        for i in 1...2 {
                            let f = CGFloat(i) / 3
                            let x = keptRect.minX + keptRect.width * f
                            p.move(to: CGPoint(x: x, y: keptRect.minY))
                            p.addLine(to: CGPoint(x: x, y: keptRect.maxY))
                            let y = keptRect.minY + keptRect.height * f
                            p.move(to: CGPoint(x: keptRect.minX, y: y))
                            p.addLine(to: CGPoint(x: keptRect.maxX, y: y))
                        }
                    }
                    .stroke(tint.opacity(0.28), lineWidth: max(0.5, lineWidth * 0.45))
                }
                Path { p in p.addRect(keptRect) }
                    .stroke(tint.opacity(0.75),
                            style: StrokeStyle(lineWidth: lineWidth,
                                               dash: [lineWidth * 5, lineWidth * 4]))
            }
        }
        .allowsHitTesting(false)
    }

    /// What survives the crop, within the picture as displayed.
    static func keptSize(shown: CGSize, cellAspect: CGFloat, cropMode: CropMode) -> CGSize {
        // `fit` letterboxes the whole photograph into the slot — nothing is
        // trimmed, so there is nothing to mark off.
        guard cropMode == .fill, cellAspect > 0 else { return shown }
        return fit(aspect: cellAspect, in: shown)
    }

    static func fit(aspect: CGFloat, in bounds: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0, aspect > 0 else { return bounds }
        let byWidth = CGSize(width: bounds.width, height: bounds.width / aspect)
        return byWidth.height <= bounds.height
            ? byWidth
            : CGSize(width: bounds.height * aspect, height: bounds.height)
    }

    private static func centred(_ size: CGSize, in bounds: CGSize) -> CGRect {
        CGRect(x: (bounds.width - size.width) / 2,
               y: (bounds.height - size.height) / 2,
               width: size.width, height: size.height)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    /// Kept so existing call sites still compile; the console ignores it. The
    /// operator's accent belongs to the print and the booth screen, and the
    /// reference is explicit that no brand hue enters the interface.
    var tint: Color = Palette.ink
    /// Cancel and its like: the one red the system allows.
    var destructive: Bool = false
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.touchControls) private var touch

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VHS.mono(touch ? (compact ? 12 : 13) : (compact ? 11 : 12), .bold))
            .tracking(1.2)
            .textCase(.uppercase)
            .padding(.horizontal, touch ? (compact ? 16 : 22) : (compact ? 10 : 14))
            .padding(.vertical, touch ? (compact ? 15 : 20) : (compact ? 6 : 8))
            .frame(maxWidth: .infinity)
            .frame(minHeight: touch ? (compact ? 50 : 60) : 0)
            .background(fill(pressed: configuration.isPressed), in: Capsule())
            .foregroundStyle(isEnabled ? Palette.surfaceAlt : Palette.midGray)
            .contentShape(Capsule())
    }

    /// Ink on paper: the reference's one and only primary treatment. `tint` is
    /// ignored here — the operator's accent colour belongs to the print and the
    /// booth, and the system is explicit that no brand hue enters the interface.
    ///
    /// The shape is a `Capsule` rather than the reference's flat 18pt radius:
    /// 18 on a 36pt button is a pill, and pill geometry is what the system
    /// actually asks for. These buttons run 44–60pt for touch, where 18 would
    /// read as a rounded rectangle instead.
    private func fill(pressed: Bool) -> Color {
        guard isEnabled else { return Palette.canvas }
        if destructive { return pressed ? Palette.ember.opacity(0.8) : Palette.ember }
        return pressed ? Palette.midGray : Palette.ink
    }
}

struct QuietButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.touchControls) private var touch

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VHS.mono(touch ? 12 : 11, .semibold))
            .tracking(1.0)
            .textCase(.uppercase)
            .padding(.horizontal, touch ? 16 : 10)
            .padding(.vertical, touch ? 18 : 7)
            .frame(maxWidth: .infinity)
            .frame(minHeight: touch ? 54 : 0)
            .background(configuration.isPressed ? Palette.hairline : Palette.canvas, in: Capsule())
            .foregroundStyle(tint)
            // Without this the gaps between glyphs are dead space to a fingertip.
            .contentShape(Capsule())
    }

    /// The reference's secondary: a tonal sibling of the primary, same shape and
    /// type, differing only in lightness. Destructive borrows the one red.
    private var tint: Color {
        guard isEnabled else { return Palette.midGray.opacity(0.5) }
        return destructive ? Palette.ember : Palette.ink
    }
}

// MARK: - Banner

struct BannerView: View {
    let message: BoothController.BannerMessage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(message.text)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(VHS.black)
        .font(VHS.mono(12, .bold))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(message.tint)
        .overlay(Rectangle().stroke(VHS.black.opacity(0.4), lineWidth: 1)
            .allowsHitTesting(false))
    }

    private var icon: String {
        switch message.kind {
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }
}

// MARK: - Displays

extension NSScreen {
    var displayIDString: String {
        let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return n.map { "\($0.uint32Value)" } ?? ""
    }

    /// "Studio Display — 2560 × 1440". Reported in pixels, because that is the
    /// number on the monitor's box; a panel driven at 2× is only half that in
    /// points, and an operator picking a display should not have to know.
    var boothLabel: String {
        let pts = "\(Int(frame.width)) × \(Int(frame.height))"
        guard backingScaleFactor != 1 else { return "\(localizedName) — \(pts)" }
        let w = Int(frame.width * backingScaleFactor)
        let h = Int(frame.height * backingScaleFactor)
        return "\(localizedName) — \(w) × \(h) (\(pts) pt)"
    }

    /// Shrinks a desired window size to what this screen can actually show.
    ///
    /// Window sizes are authored against a roomy desktop, but a booth Mac is
    /// often driven at a scaled resolution: a 1080p panel at 2× reports 960 × 540
    /// points, and `visibleFrame` takes the menu bar and Dock off that again. A
    /// window that ignores this opens with its controls off the bottom of the
    /// screen, where nobody can reach them at 2am.
    func fitting(_ desired: NSSize, margin: CGFloat = 0) -> NSSize {
        let usable = visibleFrame.size
        return NSSize(width: min(desired.width, max(320, usable.width - margin * 2)),
                      height: min(desired.height, max(240, usable.height - margin * 2)))
    }
}

// MARK: - Pictures the console draws over and over

/// Images read from disk, kept in memory.
///
/// A SwiftUI body runs every time anything it watches changes — and while a box
/// is being dragged in the layout editor, that is every frame. Reading a
/// photograph or a logo off the disk from inside a body therefore means
/// decoding it tens of times a second: the editor's artwork, the gallery's
/// prints, the loops. On a Mac mini with an evening's work in the library it is
/// what makes the application appear to stop.
///
/// Keyed by the file's path *and* the moment it was last written, so a print
/// rebuilt after a retake or an exposure change is picked up rather than being
/// served from memory for ever.
enum PictureCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 80
        return c
    }()

    static func image(at url: URL) -> NSImage? {
        let stamp = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .map { $0.timeIntervalSince1970 } ?? 0
        let key = "\(url.path)|\(stamp)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}
