import SwiftUI
import AppKit

// MARK: - Palette

enum Palette {
    static let boothBG      = VHS.black
    static let boothBGLift  = VHS.field
    static let panel        = Color(red: 0.055, green: 0.058, blue: 0.066)
    static let panelHead    = Color(red: 0.086, green: 0.090, blue: 0.100)
    static let hairline     = VHS.phosphor.opacity(0.16)
    static let text         = VHS.phosphor
    static let textDim      = VHS.dim
}

// MARK: - 4:3 stage

/// Fits a 4:3 canvas inside whatever space the display gives us and centres it.
/// The guest layout is authored once against that canvas, so nothing important is
/// ever cropped on a 4:3 booth screen or letterboxed oddly on a 16:9 laptop.
struct FourThreeStage<Content: View>: View {
    var background: Color = Palette.boothBG
    @ViewBuilder var content: (CGSize) -> Content

    var body: some View {
        GeometryReader { geo in
            let target = fit(CGSize(width: 4, height: 3), in: geo.size)
            ZStack {
                background.ignoresSafeArea()
                content(target)
                    .frame(width: target.width, height: target.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
    }

    private func fit(_ ratio: CGSize, in bounds: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / ratio.width, bounds.height / ratio.height)
        return CGSize(width: ratio.width * scale, height: ratio.height * scale)
    }
}

/// Scales guest typography with the stage so the booth reads the same on a
/// 1024×768 booth panel and a 27" iMac.
struct StageMetrics {
    let size: CGSize
    var unit: CGFloat { size.width / 100 }          // 1 unit = 1% of stage width
    func pt(_ u: CGFloat) -> CGFloat { u * unit }
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

            VStack(alignment: .leading, spacing: 13) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 13)
        }
        // Minimal: a heading, a rule, and the controls. No panel fill, no border,
        // no brackets — each of those was a extra layer to composite per card.
        .padding(.horizontal, 2)
    }
}

struct LabeledRow<Content: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
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

/// A dashed rectangle showing exactly what the chosen layout will keep.
struct CropGuide: View {
    let aspect: CGFloat
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let box = fitted(in: geo.size)
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(tint.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .frame(width: box.width, height: box.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    private func fitted(in bounds: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0, aspect > 0 else { return .zero }
        let byWidth = CGSize(width: bounds.width, height: bounds.width / aspect)
        if byWidth.height <= bounds.height { return byWidth }
        return CGSize(width: bounds.height * aspect, height: bounds.height)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = VHS.amber
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VHS.mono(compact ? 11 : 12, .bold))
            .tracking(1.2)
            .textCase(.uppercase)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 6 : 8)
            .frame(maxWidth: .infinity)
            .background(fill(pressed: configuration.isPressed))
            .foregroundStyle(isEnabled ? VHS.black : VHS.dim)
    }

    private func fill(pressed: Bool) -> Color {
        guard isEnabled else { return Color.white.opacity(0.04) }
        return tint.opacity(pressed ? 0.72 : 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VHS.mono(11, .semibold))
            .tracking(1.0)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.045))
            .foregroundStyle(tint)
    }

    private var tint: Color {
        guard isEnabled else { return VHS.dim.opacity(0.6) }
        return destructive ? VHS.rec : VHS.phosphor
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
        .overlay(Rectangle().stroke(VHS.black.opacity(0.4), lineWidth: 1))
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

    /// "Studio Display — 2560 × 1440"
    var boothLabel: String {
        "\(localizedName) — \(Int(frame.width)) × \(Int(frame.height))"
    }
}
