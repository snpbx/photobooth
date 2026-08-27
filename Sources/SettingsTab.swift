import SwiftUI
import AppKit
import AVFoundation

struct SettingsTab: View {
    @ObservedObject var c: BoothController
    @State private var confirmReset = false

    var body: some View {
        GeometryReader { geo in
            let cols = geo.size.width < 820 ? 1 : (geo.size.width < 1280 ? 2 : 3)
            ScrollView {
                ResponsiveColumns(count: cols, spacing: 42) {
                    [
                        AnyView(BrandingCard(c: c)),
                        AnyView(PrintQualityCard(c: c)),
                        AnyView(CameraAdvancedCard(c: c)),
                        AnyView(GuestQRCard(c: c)),
                        AnyView(InterfaceCard(c: c)),
                        AnyView(MaintenanceCard(c: c, confirmReset: $confirmReset))
                    ]
                }
                .frame(maxWidth: 1760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
        }
        .alert("Reset all settings?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { c.settingsService.resetToDefaults() }
        } message: {
            Text("Timing, layout, printer and branding return to their defaults. Photographs are not touched.")
        }
    }
}

/// The scan-to-download handout.
private struct GuestQRCard: View {
    @ObservedObject var c: BoothController

    private func bind<T>(_ path: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { c.settingsService.settings[keyPath: path] },
                set: { c.settingsService.settings[keyPath: path] = $0 })
    }

    var body: some View {
        SectionCard(title: "Guest QR Code") {
            Toggle("Show a QR code on the finish screen", isOn: bind(\.showQRCode))
                .font(.system(size: 12))

            Toggle("Print the QR code on the 4×6", isOn: bind(\.printQRCode))
                .font(.system(size: 12))
            if c.settings.printQRCode {
                Text("The footer strip grows to about 24 mm so the printed code is large enough for a phone to read.")
                    .font(.system(size: 11))
                    .foregroundStyle(VHS.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.4)

            LabeledRow(label: "The code opens") {
                Picker("", selection: bind(\.qrTarget)) {
                    ForEach(QRTarget.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }

            if c.settings.qrTarget == .eventAlbum {
                Text("The code opens the event's album page — every session from the night, online. It is password-protected, so tell guests the password or hand it to the client only.")
                    .font(.system(size: 11))
                    .foregroundStyle(VHS.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = c.qrTargetProblem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(VHS.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledRow(label: "Caption") {
                    TextField("", text: bind(\.qrCaption))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
            }

            // Their photos — the session's own album page, so a guest scans once
            // and gets their own frames rather than the whole event.
            if c.settings.qrTarget != .customLink && c.settings.qrTarget != .eventAlbum {
                LabeledRow(label: "Photos caption") {
                    TextField("", text: bind(\.qrCaption))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                Toggle("Only show it once the photos are online", isOn: bind(\.qrRequiresUpload))
                    .font(.system(size: 12))
                Text(c.settings.qrRequiresUpload
                     ? "With no internet at the venue the code is held back rather than sent to a page that does not exist yet. It appears by itself the moment the upload lands — even with the finish screen still up. The 4×6 still carries its printed code."
                     : "The code is shown as soon as the session ends. Scanned before the upload finishes, it leads nowhere.")
                    .font(.system(size: 11))
                    .foregroundStyle(c.settings.qrRequiresUpload ? VHS.dim : VHS.amber)
                    .fixedSize(horizontal: false, vertical: true)

                // Where the photos code points depends on the host, so the copy
                // has to follow it rather than always talking about a site address.
                if let problem = c.qrTargetProblem, c.settings.qrTarget == .sessionAlbum {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(VHS.amber)
                        .fixedSize(horizontal: false, vertical: true)
                } else if c.settings.galleryHost == .cloudinary {
                    Text("Opens that session's print on Cloudinary — the one image holding every photograph from the session.")
                        .font(.system(size: 11))
                        .foregroundStyle(VHS.dim)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !c.settings.uploadBaseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Links to that session's own page on \(c.settings.uploadBaseURL).")
                        .font(.system(size: 11))
                        .foregroundStyle(VHS.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // The operator's own address: Instagram, a website, a link tree.
            if c.settings.qrTarget == .customLink || c.settings.qrTarget == .both {
                LabeledRow(label: "My link") {
                    TextField("instagram.com/yourbooth", text: bind(\.customQRLink))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                LabeledRow(label: "Link caption") {
                    TextField("", text: bind(\.customQRCaption))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }

                HStack(alignment: .top, spacing: 12) {
                    // Proof, not a promise: this is the code the booth will show.
                    if let preview = c.makeBrandQR(side: 220) {
                        Image(nsImage: preview)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 86, height: 86)
                            .padding(5)
                            .background(Color.white)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        if let url = c.customQRURL {
                            Text(url.absoluteString)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(VHS.dim)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open Link") { NSWorkspace.shared.open(url) }
                                .buttonStyle(QuietButtonStyle())
                        } else {
                            Text(c.settings.customQRLink.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? "Type the address the code should open. \"instagram.com/yourbooth\" is enough — https:// is added for you."
                                 : "That does not look like a web address. Check for a typo or a stray space.")
                                .font(.system(size: 11))
                                .foregroundStyle(VHS.amber)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                }
            }

            if c.settings.qrTarget == .both {
                Text("Two cards on the finish screen — their photos, and your page. The 4×6 has room for one, and carries the photo link.")
                    .font(.system(size: 11))
                    .foregroundStyle(VHS.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct BrandingCard: View {
    @ObservedObject var c: BoothController

    var body: some View {
        SectionCard(title: "Branding") {
            field("Event title", text: Binding(
                get: { c.settingsService.settings.eventTitle },
                set: { c.settingsService.settings.eventTitle = $0 }),
                help: "Shown on the idle screen and printed in the strip footer.")

            field("Idle headline", text: Binding(
                get: { c.settingsService.settings.idleHeadline },
                set: { c.settingsService.settings.idleHeadline = $0 }))

            field("Idle subhead", text: Binding(
                get: { c.settingsService.settings.idleSubhead },
                set: { c.settingsService.settings.idleSubhead = $0 }))

            Toggle("Print footer", isOn: Binding(
                get: { c.settingsService.settings.footerEnabled },
                set: { c.settingsService.settings.footerEnabled = $0 }))
                .font(.system(size: 12))

            field("Footer text", text: Binding(
                get: { c.settingsService.settings.footerText },
                set: { c.settingsService.settings.footerText = $0 }),
                help: "Leave empty to print the event title.")
                .disabled(!c.settings.footerEnabled)

            LabeledRow(label: "Accent colour") {
                HexColorField(hex: Binding(
                    get: { c.settingsService.settings.accentHex },
                    set: { c.settingsService.settings.accentHex = $0 }))
            }
            LabeledRow(label: "Print background") {
                HexColorField(hex: Binding(
                    get: { c.settingsService.settings.backgroundHex },
                    set: { c.settingsService.settings.backgroundHex = $0 }))
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            TextField("", text: text).textFieldStyle(.roundedBorder)
            if let help {
                Text(help).font(.system(size: 11)).foregroundStyle(VHS.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct HexColorField: View {
    @Binding var hex: String

    var body: some View {
        HStack(spacing: 7) {
            ColorPicker("", selection: Binding(
                get: { Color(hex: hex) },
                set: { hex = $0.hexString }), supportsOpacity: false)
                .labelsHidden()
            TextField("", text: $hex)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}

private struct PrintQualityCard: View {
    @ObservedObject var c: BoothController

    var body: some View {
        SectionCard(title: "Print Quality & Geometry") {
            LabeledRow(label: "Resolution", help: "300 DPI matches the SELPHY's native 4×6 output.") {
                Picker("", selection: Binding(
                    get: { c.settingsService.settings.dpi },
                    set: { c.settingsService.settings.dpi = $0 })) {
                        Text("200 DPI").tag(200)
                        Text("300 DPI").tag(300)
                        Text("600 DPI").tag(600)
                }
                .labelsHidden().frame(width: 120)
            }

            LabeledRow(label: "Photo fitting",
                       help: c.settings.cropMode == .fill
                        ? "Photos fill each slot; edges outside the slot are trimmed. Nothing is stretched."
                        : "Whole photo is kept; the slot shows background at the sides.") {
                Picker("", selection: Binding(
                    get: { c.settingsService.settings.cropMode },
                    set: { c.settingsService.settings.cropMode = $0 })) {
                        ForEach(CropMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 160)
            }

            LabeledRow(label: "Outer margin") {
                DoubleStepper(value: Binding(
                    get: { c.settingsService.settings.outerMarginInches },
                    set: { c.settingsService.settings.outerMarginInches = $0 }),
                    range: 0...0.6, step: 0.02, suffix: "in")
            }
            LabeledRow(label: "Gap between photos") {
                DoubleStepper(value: Binding(
                    get: { c.settingsService.settings.gutterInches },
                    set: { c.settingsService.settings.gutterInches = $0 }),
                    range: 0...0.4, step: 0.01, suffix: "in")
            }

            Divider().opacity(0.4)

            HStack(alignment: .top, spacing: 12) {
                if let img = LayoutRenderer.schematic(for: c.settings.layout, settings: c.settings, width: 320) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.hairline))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.settings.layout.title).font(.system(size: 12, weight: .semibold))
                    Text("Canvas \(Int(c.settings.pixelSize.width)) × \(Int(c.settings.pixelSize.height)) px")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(VHS.dim)
                    Text(String(format: "Slot aspect %.2f : 1",
                                LayoutRenderer.cellAspect(for: c.settings.layout, settings: c.settings)))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(VHS.dim)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct CameraAdvancedCard: View {
    @ObservedObject var c: BoothController

    var body: some View {
        SectionCard(title: "Camera Advanced") {
            LabeledRow(label: "Live view frame rate",
                       help: "Lower this if the USB link struggles or the 6D warms up during long events.") {
                IntStepper(value: Binding(
                    get: { c.settingsService.settings.liveViewFPS },
                    set: { c.settingsService.settings.liveViewFPS = $0 }),
                    range: 1...30, suffix: "fps")
            }

            if c.settings.cameraBackend == .webcam {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Video device").font(.system(size: 12, weight: .medium))
                    Picker("", selection: Binding(
                        get: { c.settingsService.settings.webcamUniqueID },
                        set: { c.settingsService.settings.webcamUniqueID = $0 })) {
                            Text("First available").tag("")
                            ForEach(WebcamCameraService.availableDevices(), id: \.uniqueID) { d in
                                Text(d.localizedName).tag(d.uniqueID)
                            }
                    }
                    .labelsHidden()
                }
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 6) {
                Text("CANON EOS 6D SETUP")
                    .font(.system(size: 10, weight: .semibold)).tracking(1)
                    .foregroundStyle(VHS.dim)
                bullet("Mode dial on M or Av — fully automatic modes block remote capture.")
                bullet("Set the lens to AF and leave the card in; shots are copied off and then removed.")
                bullet("Turn off auto power-off, or the camera sleeps between guests.")
                bullet("Quit Image Capture and Photos — they claim the camera before this app can.")
            }
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(VHS.dim)
            Text(s).font(.system(size: 11)).foregroundStyle(VHS.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct InterfaceCard: View {
    @ObservedObject var c: BoothController

    var body: some View {
        SectionCard(title: "Interface") {
            Toggle("Open the booth window full screen", isOn: Binding(
                get: { c.settingsService.settings.fullScreenOnLaunch },
                set: { c.settingsService.settings.fullScreenOnLaunch = $0 }))
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text("Admin passcode").font(.system(size: 12, weight: .medium))
                SecureField("Leave empty for no passcode", text: Binding(
                    get: { c.settingsService.settings.adminPasscode },
                    set: { c.settingsService.settings.adminPasscode = $0 }))
                    .textFieldStyle(.roundedBorder)
                Text("Asked for when leaving Booth Mode, so guests cannot reach these controls.")
                    .font(.system(size: 11)).foregroundStyle(VHS.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 6) {
                Text("SHORTCUTS")
                    .font(.system(size: 10, weight: .semibold)).tracking(1)
                    .foregroundStyle(VHS.dim)
                shortcut("⌘B", "Open or close the booth window")
                shortcut("⌘1 / ⌘2", "Admin window / booth window")
                shortcut("ESC", "From the booth window, reveal Admin")
                shortcut("Space / ⏎", "Start a session on the idle screen")
                shortcut("⌘⏎", "Start a session from Admin")
                shortcut("⌘.", "Cancel the running session")
                shortcut("⌃⌘F", "Toggle full screen")
            }
        }
    }

    private func shortcut(_ key: String, _ what: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                .frame(minWidth: 54, alignment: .center)
            Text(what).font(.system(size: 11)).foregroundStyle(VHS.dim)
            Spacer(minLength: 0)
        }
    }
}

private struct MaintenanceCard: View {
    @ObservedObject var c: BoothController
    @Binding var confirmReset: Bool

    var body: some View {
        SectionCard(title: "Maintenance") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings file").font(.system(size: 12, weight: .medium))
                Text(c.settingsService.settingsFileURL.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(VHS.dim)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Log folder").font(.system(size: 12, weight: .medium))
                Text(Log.shared.logDirectory.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(VHS.dim)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button("Reveal Settings") {
                    NSWorkspace.shared.activateFileViewerSelecting([c.settingsService.settingsFileURL])
                }
                .buttonStyle(QuietButtonStyle())
                Button("Reveal Logs") {
                    NSWorkspace.shared.activateFileViewerSelecting([Log.shared.logDirectory])
                }
                .buttonStyle(QuietButtonStyle())
            }

            Button("Reset Settings…") { confirmReset = true }
                .buttonStyle(QuietButtonStyle(destructive: true))

            Divider().opacity(0.4)

            Text("Photobooth \(Bundle.main.appVersion) · \(c.settings.cameraBackend.title)")
                .font(.system(size: 11)).foregroundStyle(VHS.dim)
        }
    }
}

// MARK: - Helpers

extension Color {
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
