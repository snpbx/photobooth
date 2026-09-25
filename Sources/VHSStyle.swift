import SwiftUI
import AppKit

/// The 1990s camcorder on-screen-display look: a black field, dot-matrix capitals
/// with VHS colour fringing, scanlines and a soft vignette.
///
/// macOS ships no dot-matrix face, so the character is built rather than set:
/// heavy monospaced glyphs, wide tracking, a red/cyan split behind the white, and
/// a little bloom. That reads as a camcorder OSD without shipping a font.
enum VHS {
    // Phosphor palette
    static let black     = Color(red: 0.016, green: 0.016, blue: 0.020)
    static let field     = Color(red: 0.035, green: 0.038, blue: 0.043)
    static let phosphor  = Color(red: 0.949, green: 0.949, blue: 0.925)
    static let dim       = Color(red: 0.541, green: 0.545, blue: 0.510)
    static let amber     = Color(red: 1.000, green: 0.690, blue: 0.000)
    static let rec       = Color(red: 1.000, green: 0.231, blue: 0.188)
    static let ok        = Color(red: 0.310, green: 0.980, blue: 0.470)
    static let fringeA   = Color(red: 1.0, green: 0.15, blue: 0.35)   // magenta-red edge
    static let fringeB   = Color(red: 0.20, green: 0.85, blue: 1.0)   // cyan edge

    /// The OSD is authored against a 1000pt-wide stage and scaled, so the same
    /// numbers work on a 1024×768 booth panel and a 27" display.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// "21.08.2026 FRI" — the camcorder date stamp.
    static func dateStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        let day = DateFormatter()
        day.dateFormat = "EEE"
        return "\(f.string(from: d)) \(day.string(from: d).uppercased())"
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// Timecode counter, "00:02:20".
    static func timecode(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }
}

// MARK: - Light rendering

private struct VHSLightRenderingKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set once on the booth stage. Read by the pieces that would otherwise
    /// animate or blur forever, so the switch lives in one place instead of at
    /// every call site.
    var vhsLightRendering: Bool {
        get { self[VHSLightRenderingKey.self] }
        set { self[VHSLightRenderingKey.self] = newValue }
    }
}

// MARK: - Fringed OSD text

/// A line of camcorder OSD text: white glyphs with a red/cyan chromatic split and
/// a faint bloom, exactly as a tape-era viewfinder smears its overlay.
struct VHSText: View {
    let text: String
    var size: CGFloat = 16
    var weight: Font.Weight = .bold
    var color: Color = VHS.phosphor
    var tracking: CGFloat = 0.14      // as a fraction of size
    var fringe: CGFloat = 1.0         // 0 disables the colour split

    @Environment(\.vhsLightRendering) private var light

    var body: some View {
        // Light rendering takes the flat path: the fringe is three Texts and two
        // blurs per string, recomposited over the live view on every frame.
        if fringe <= 0 || light {
            // Flat path: a single Text, no layers, no blur, no compositing group.
            // This is what the console uses — same typography, none of the cost.
            base.foregroundStyle(color)
        } else {
            let split = max(0.6, size * 0.045) * fringe
            ZStack {
                base.foregroundStyle(VHS.fringeA)
                    .offset(x: -split, y: 0)
                    .blur(radius: split * 0.7)
                    .blendMode(.screen)
                base.foregroundStyle(VHS.fringeB)
                    .offset(x: split, y: 0)
                    .blur(radius: split * 0.7)
                    .blendMode(.screen)
                base.foregroundStyle(color)
                    .shadow(color: color.opacity(0.55), radius: size * 0.10)
            }
            .compositingGroup()
        }
    }

    private var base: some View {
        Text(text.uppercased())
            .font(VHS.mono(size, weight))
            .tracking(size * tracking)
            .lineSpacing(size * 0.28)
    }
}

/// Console label: monospaced capitals with OSD tracking and nothing else.
/// Cheap enough to use on every row of a dense control panel.
struct OSDLabel: View {
    let text: String
    var size: CGFloat = 11
    var weight: Font.Weight = .semibold
    var color: Color = VHS.phosphor
    var tracking: CGFloat = 0.10

    var body: some View {
        Text(text.uppercased())
            .font(VHS.mono(size, weight))
            .tracking(size * tracking)
            .foregroundStyle(color)
    }
}

// MARK: - Screen furniture

/// Horizontal scanlines. Drawn in a Canvas so a full-screen overlay stays cheap.
struct Scanlines: View {
    var spacing: CGFloat = 3
    var opacity: Double = 0.22

    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            let line = Path(CGRect(x: 0, y: 0, width: size.width, height: 1))
            while y < size.height {
                ctx.translateBy(x: 0, y: y == 0 ? 0 : spacing)
                ctx.fill(line, with: .color(.black.opacity(opacity)))
                y += spacing
            }
        }
        .allowsHitTesting(false)
        .drawingGroup(opaque: false)
    }
}

/// Darkened corners, as though looking through an eyepiece.
struct Vignette: View {
    var strength: Double = 0.55

    var body: some View {
        RadialGradient(
            stops: [
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(strength * 0.5), location: 0.80),
                .init(color: .black.opacity(strength), location: 1.0)
            ],
            center: .center, startRadius: 0, endRadius: 900
        )
        .allowsHitTesting(false)
    }
}

/// The whole CRT treatment in one modifier: scanlines, vignette and a faint
/// horizontal tracking band that drifts, so the screen never looks quite static.
struct CRTOverlay: View {
    var scanlineSpacing: CGFloat = 3
    /// How dark the scanlines and the vignette are. Both are dialled back while
    /// a guest is framing: the camcorder dress is worth having, but not at the
    /// cost of somebody being unable to see whether they are in the shot.
    var scanlineOpacity: Double = 0.22
    var vignetteStrength: Double = 0.55
    var showsTrackingBand = true
    @State private var bandY: CGFloat = -0.2

    @Environment(\.vhsLightRendering) private var light

    /// The band is the single most expensive thing on the guest screen: a
    /// full-width gradient sliding down the whole picture on a seven-second
    /// loop that never ends, which means the entire frame is redrawn at display
    /// rate even when the booth has been idle for an hour. Scanlines and the
    /// vignette are static, so they stay — once drawn they cost nothing to hold.
    private var bandVisible: Bool { showsTrackingBand && !light }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Scanlines(spacing: scanlineSpacing, opacity: scanlineOpacity)
                Vignette(strength: vignetteStrength)
                if bandVisible {
                    LinearGradient(colors: [.clear, .white.opacity(0.045), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.size.height * 0.10)
                        .offset(y: bandY * geo.size.height)
                        .blendMode(.screen)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard bandVisible else { return }
            withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
                bandY = 1.2
            }
        }
    }
}

/// Viewfinder corner brackets around the framed area.
struct CornerBrackets: View {
    var color: Color = VHS.phosphor
    var length: CGFloat = 28
    var thickness: CGFloat = 2
    var inset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                let l = min(length, min(w, h) / 3)
                // top-left
                p.move(to: CGPoint(x: inset, y: inset + l)); p.addLine(to: CGPoint(x: inset, y: inset)); p.addLine(to: CGPoint(x: inset + l, y: inset))
                // top-right
                p.move(to: CGPoint(x: w - inset - l, y: inset)); p.addLine(to: CGPoint(x: w - inset, y: inset)); p.addLine(to: CGPoint(x: w - inset, y: inset + l))
                // bottom-right
                p.move(to: CGPoint(x: w - inset, y: h - inset - l)); p.addLine(to: CGPoint(x: w - inset, y: h - inset)); p.addLine(to: CGPoint(x: w - inset - l, y: h - inset))
                // bottom-left
                p.move(to: CGPoint(x: inset + l, y: h - inset)); p.addLine(to: CGPoint(x: inset, y: h - inset)); p.addLine(to: CGPoint(x: inset, y: h - inset - l))
            }
            .stroke(color, style: StrokeStyle(lineWidth: thickness, lineCap: .square))
        }
        .allowsHitTesting(false)
    }
}

/// Blinking capture lamp. `glow` costs a shadow pass, so the console leaves it off.
struct CaptureLamp: View {
    var size: CGFloat = 10
    var active: Bool = true
    var glow: Bool = true
    @State private var on = true

    @Environment(\.vhsLightRendering) private var light

    var body: some View {
        let glows = glow && !light
        Circle()
            .fill(VHS.rec)
            .frame(width: size, height: size)
            .shadow(color: glows ? VHS.rec.opacity(0.8) : .clear, radius: glows ? size * 0.5 : 0)
            .opacity(active ? (on ? 1 : 0.15) : 0.25)
            .onAppear {
                // A blink is a redraw twice a second for as long as the booth is
                // open. Steady costs nothing and still reads as a record lamp.
                guard active, !light else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { on = false }
            }
    }
}

/// Segmented battery/tape gauge, as on a camcorder status strip.
struct TapeGauge: View {
    var filled: Int
    var total: Int = 4
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: size * 0.22) {
            ForEach(0..<total, id: \.self) { i in
                Rectangle()
                    .fill(i < filled ? VHS.phosphor : VHS.phosphor.opacity(0.22))
                    .frame(width: size * 0.55, height: size)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(VHS.phosphor.opacity(0.5))
                .frame(width: size * 0.16, height: size * 0.45)
                .offset(x: size * 0.30)
        }
    }
}

// MARK: - A live clock the OSD can bind to

/// One ticking clock shared by every readout, so the stamps never disagree.
@MainActor
final class OSDClock: ObservableObject {
    static let shared = OSDClock()
    @Published private(set) var now = Date()
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }
}
