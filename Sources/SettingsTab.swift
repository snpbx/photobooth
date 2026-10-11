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
                        AnyView(CameraBodyCard(c: c)),
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
                    .foregroundStyle(Palette.textDim)
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
                    .foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = c.qrTargetProblem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.statusWarn)
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
                    .foregroundStyle(c.settings.qrRequiresUpload ? Palette.textDim : Palette.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)

                // Where the photos code points depends on the host, so the copy
                // has to follow it rather than always talking about a site address.
                if let problem = c.qrTargetProblem, c.settings.qrTarget == .sessionAlbum {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.statusWarn)
                        .fixedSize(horizontal: false, vertical: true)
                } else if c.settings.galleryHost == .cloudinary {
                    Text("Opens that session's print on Cloudinary — the one image holding every photograph from the session.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !c.settings.uploadBaseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Links to that session's own page on \(c.settings.uploadBaseURL).")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textDim)
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
                                .foregroundStyle(Palette.textDim)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open Link") { NSWorkspace.shared.open(url) }
                                .buttonStyle(QuietButtonStyle())
                        } else {
                            Text(c.settings.customQRLink.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? "Type the address the code should open. \"instagram.com/yourbooth\" is enough — https:// is added for you."
                                 : "That does not look like a web address. Check for a typo or a stray space.")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.statusWarn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                }
            }

            if c.settings.qrTarget == .both {
                Text("Two cards on the finish screen — their photos, and your page. The 4×6 has room for one, and carries the photo link.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textDim)
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

            idleLogoRow

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
                .disabled(!c.settings.footerEnabled || hasFooterImage)

            footerImageRow

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

    private var hasFooterImage: Bool {
        BrandingAssets.url(for: c.settings.footerImageFile) != nil
    }

    /// Artwork for the footer, in place of the typed text.
    ///
    /// Shown as a thumbnail on the print's own background colour rather than on
    /// the console's black, because a white logo on a white 4×6 is invisible and
    /// an operator should find that out here rather than on the first sheet.
    @ViewBuilder
    private var footerImageRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Footer image").font(.system(size: 12, weight: .medium))

            if let url = BrandingAssets.url(for: c.settings.footerImageFile),
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 56)
                    .padding(6)
                    .background(Color(hex: c.settings.backgroundHex))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.hairline)
                        .allowsHitTesting(false))
            }

            HStack(spacing: 8) {
                Button(hasFooterImage ? "Replace Image…" : "Choose Image…") { chooseFooterImage() }
                if hasFooterImage {
                    Button("Remove") {
                        let old = c.settingsService.settings.footerImageFile
                        c.settingsService.settings.footerImageFile = ""
                        BrandingAssets.remove(old)
                    }
                }
            }
            .font(.system(size: 12))

            Text(hasFooterImage
                 ? "Printed in place of the footer text. PNG transparency is kept, so a logo sits on the print background."
                 : "Optional. A PNG, JPEG or TIFF printed in place of the footer text — a client logo, say. It is copied into the app's own folder, so it keeps printing after the original is moved or deleted.")
                .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!c.settings.footerEnabled)
    }

    private var hasIdleLogo: Bool { BrandingAssets.url(for: c.settings.idleLogoFile) != nil }

    /// The mark the guest screen opens on.
    ///
    /// White-on-transparent artwork is what suits it: the idle screen is black,
    /// or a live picture, and a logo drawn for white paper disappears into both.
    @ViewBuilder
    private var idleLogoRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Idle logo").font(.system(size: 12, weight: .medium))

            if hasIdleLogo, let u = BrandingAssets.url(for: c.settings.idleLogoFile),
               let img = NSImage(contentsOf: u) {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 54)
                    .padding(8)
                    // Shown on black, because that is where it has to work.
                    .background(Color.black, in: RoundedRectangle(cornerRadius: Palette.smallRadius))
            }

            HStack(spacing: 8) {
                Button(hasIdleLogo ? "Replace Logo…" : "Choose Logo…") { chooseIdleLogo() }
                if hasIdleLogo {
                    Button("Remove") {
                        let old = c.settingsService.settings.idleLogoFile
                        c.settingsService.settings.idleLogoFile = ""
                        BrandingAssets.remove(old)
                    }
                }
            }
            .font(.system(size: 12))

            if hasIdleLogo {
                LabeledRow(label: "Logo width",
                           help: "As a share of the guest screen, so it holds its size on any panel.") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { c.settingsService.settings.idleLogoWidth },
                            set: { c.settingsService.settings.idleLogoWidth = $0 }),
                            in: 0.15...0.9)
                            .frame(width: 120)
                        Text("\(Int(c.settings.idleLogoWidth * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.textDim)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            Text(hasIdleLogo
                 ? "Shown on the idle screen in place of the event title."
                 : "Optional. Shown on the idle screen in place of the event title. The screen is black or a live picture, so pale artwork on a transparent background reads best.")
                .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseIdleLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .image]
        panel.prompt = "Use Logo"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let previous = c.settingsService.settings.idleLogoFile
            let name = try BrandingAssets.importImage(from: url)
            c.settingsService.settings.idleLogoFile = name
            if previous != name { BrandingAssets.remove(previous) }
        } catch {
            c.show(.warning, error.localizedDescription)
        }
    }

    private func chooseFooterImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .image]
        panel.prompt = "Use Image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let previous = c.settingsService.settings.footerImageFile
            let name = try BrandingAssets.importImage(from: url)
            c.settingsService.settings.footerImageFile = name
            // Only after the new one is safely in place.
            if previous != name { BrandingAssets.remove(previous) }
        } catch {
            c.show(.warning, error.localizedDescription)
        }
    }

    private func field(_ label: String, text: Binding<String>, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            TextField("", text: text).textFieldStyle(.roundedBorder)
            if let help {
                Text(help).font(.system(size: 11)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HexColorField: View {
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
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.hairline)
                            .allowsHitTesting(false))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.settings.layout.title).font(.system(size: 12, weight: .semibold))
                    Text("Canvas \(Int(c.settings.pixelSize.width)) × \(Int(c.settings.pixelSize.height)) px")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.textDim)
                    Text(String(format: "Slot aspect %.2f : 1",
                                LayoutRenderer.cellAspect(for: c.settings.layout, settings: c.settings)))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.textDim)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct CameraAdvancedCard: View {
    @ObservedObject var c: BoothController

    var body: some View {
        if GIFRenderer.enabled {
        SectionCard(title: "Animated GIF") {
            LabeledRow(label: "Make a GIF",
                       help: "After every session, builds a looping GIF of that session's photographs — each one filling a page in the same branding as the print. Saved beside the photographs, and on the session's webpage for guests to take away.") {
                Toggle("", isOn: Binding(
                    get: { c.settingsService.settings.makeGIF },
                    set: { c.settingsService.settings.makeGIF = $0 }))
                    .labelsHidden()
            }

            LabeledRow(label: "Hold each photo",
                       help: "How long one photograph stays on screen. With the number of photographs, this is the length of the loop.") {
                Picker("", selection: Binding(
                    get: { c.settingsService.settings.gifSeconds },
                    set: { c.settingsService.settings.gifSeconds = $0 })) {
                        Text("0.4 s — quick").tag(0.4)
                        Text("0.6 s").tag(0.6)
                        Text("0.8 s — recommended").tag(0.8)
                        Text("1.2 s").tag(1.2)
                        Text("2 s — slow").tag(2.0)
                }
                .labelsHidden().frame(width: 200)
                .disabled(!c.settings.makeGIF)
            }

            LabeledRow(label: "Size",
                       help: "Long edge of the page. This is what a guest downloads on venue wifi. \(gifSizeNote)") {
                Picker("", selection: Binding(
                    get: { c.settingsService.settings.gifLongEdge },
                    set: { c.settingsService.settings.gifLongEdge = $0 })) {
                        Text("360 px — smallest").tag(360)
                        Text("480 px — recommended").tag(480)
                        Text("640 px — larger").tag(640)
                        Text("800 px — largest").tag(800)
                }
                .labelsHidden().frame(width: 200)
                .disabled(!c.settings.makeGIF)
            }

            LabeledRow(label: "Put it on the site",
                       help: "Uploads the GIF with the photographs, so it is on the session page the guest's code opens.") {
                Toggle("", isOn: Binding(
                    get: { c.settingsService.settings.uploadGIFs },
                    set: { c.settingsService.settings.uploadGIFs = $0 }))
                    .labelsHidden()
                    .disabled(!c.settings.makeGIF)
            }
        }
        }

        SectionCard(title: "Session Video") {
            LabeledRow(label: "Record the session",
                       help: "A short film of the whole visit — the live view as it ran, the shutter, and each photograph held as it was taken, with the booth's logo on the end. Saved beside the photographs and put on the session page for guests to post.") {
                Toggle("", isOn: Binding(
                    get: { c.settingsService.settings.makeVideo },
                    set: { c.settingsService.settings.makeVideo = $0 }))
                    .labelsHidden()
            }

            LabeledRow(label: "Hold each photo",
                       help: "How long each photograph stays on screen in the film as it is taken.") {
                Picker("", selection: Binding(
                    get: { c.settingsService.settings.videoHoldSeconds },
                    set: { c.settingsService.settings.videoHoldSeconds = $0 })) {
                        Text("0.8 s").tag(0.8)
                        Text("1.2 s — recommended").tag(1.2)
                        Text("2 s").tag(2.0)
                        Text("3 s — slow").tag(3.0)
                }
                .labelsHidden().frame(width: 200)
                .disabled(!c.settings.makeVideo)
            }

            LabeledRow(label: "Size",
                       help: "Long edge of the film. The live view is the source, so beyond 720 px there is rarely more to see — only more to download.") {
                Picker("", selection: Binding(
                    get: { c.settingsService.settings.videoLongEdge },
                    set: { c.settingsService.settings.videoLongEdge = $0 })) {
                        Text("540 px — smallest").tag(540)
                        Text("720 px — recommended").tag(720)
                        Text("1080 px — largest").tag(1080)
                }
                .labelsHidden().frame(width: 200)
                .disabled(!c.settings.makeVideo)
            }

            LabeledRow(label: "Logo at the end",
                       help: "Ends the film on the booth's own mark, so a clip posted by a guest says whose booth it was.") {
                Toggle("", isOn: Binding(
                    get: { c.settingsService.settings.videoEndCard },
                    set: { c.settingsService.settings.videoEndCard = $0 }))
                    .labelsHidden()
                    .disabled(!c.settings.makeVideo)
            }

            LabeledRow(label: "Put it on the site",
                       help: "Uploads the film with the photographs, so it is on the session page the guest's code opens.") {
                Toggle("", isOn: Binding(
                    get: { c.settingsService.settings.uploadVideos },
                    set: { c.settingsService.settings.uploadVideos = $0 }))
                    .labelsHidden()
                    .disabled(!c.settings.makeVideo)
            }
        }

        SectionCard(title: "Camera Advanced") {
            LabeledRow(label: "Live view frame rate",
                       help: "Lower this if the USB link struggles or the 6D warms up during long events.") {
                IntStepper(value: Binding(
                    get: { c.settingsService.settings.liveViewFPS },
                    set: { c.settingsService.settings.liveViewFPS = $0 }),
                    range: 1...30, suffix: "fps")
            }

            LabeledRow(label: "Preview brightness",
                       help: "Lifts the live picture on the guest screen so people can see themselves to frame up. It changes the screen only — never the photograph, the print, or what the camera is set to.") {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { c.settingsService.settings.previewBrightness },
                        set: { c.settingsService.settings.previewBrightness = $0 }),
                        in: 0...0.5)
                        .frame(width: 120)
                    Text("\(Int(c.settings.previewBrightness * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.textDim)
                        .frame(width: 38, alignment: .trailing)
                }
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
                    .foregroundStyle(Palette.textDim)
                bullet("Mode dial on M or Av — fully automatic modes block remote capture.")
                bullet("Set the lens to AF and leave the card in; shots are copied off and then removed.")
                bullet("Turn off auto power-off, or the camera sleeps between guests.")
                bullet("Quit Image Capture and Photos — they claim the camera before this app can.")
            }
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(Palette.textDim)
            Text(s).font(.system(size: 11)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// ISO, aperture and the rest, read from the camera itself.
///
/// Every row here is whatever the body offered when it was last asked — nothing
/// is stored in our settings file. A setting the camera will not hand over
/// (shutter speed with the dial on Av, everything at all in a green-square mode)
/// is shown as it stands and cannot be picked, because pretending otherwise
/// would let the operator set something the camera quietly ignores.
private struct CameraBodyCard: View {
    @ObservedObject var c: BoothController

    var body: some View {
        SectionCard(title: "Camera Settings", accessory: AnyView(refreshButton)) {
            if c.settings.cameraBackend != .dslr {
                Text("Switch the camera to the Canon over USB to edit its settings.")
                    .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !c.cameraState.isReady {
                Text("Connect the camera to read its settings.")
                    .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else if c.cameraSettings.isEmpty {
                Text(c.cameraSettingsLoading
                     ? "Reading the camera…"
                     : (c.cameraSettingsError ?? "Press Read to ask the camera what it is set to."))
                    .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(c.cameraSettings) { setting in
                    row(setting)
                }
                if let err = c.cameraSettingsError {
                    Text(err).font(.system(size: 11)).foregroundStyle(Palette.statusWarn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().opacity(0.4)
                Text("Changes go straight to the camera and stay on it — they are not part of the booth's own settings, and they survive a restart of this app but not a change made on the body itself.")
                    .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { c.refreshCameraSettings() }
    }

    private var refreshButton: some View {
        Button(c.cameraSettingsLoading ? "Reading…" : "Read") { c.refreshCameraSettings() }
            .buttonStyle(QuietButtonStyle())
            // QuietButtonStyle stretches by design; in a card header it would
            // otherwise take the whole width from the title.
            .fixedSize()
            .disabled(c.cameraSettingsLoading || c.settings.cameraBackend != .dslr)
    }

    @ViewBuilder
    private func row(_ s: CameraSetting) -> some View {
        LabeledRow(label: s.label, help: help(for: s)) {
            if s.choices.isEmpty || s.readOnly {
                Text(s.value.isEmpty ? "—" : s.value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.textDim)
            } else {
                Picker("", selection: Binding(
                    get: { s.value },
                    set: { picked in
                        guard picked != s.value else { return }
                        c.setCameraSetting(s.name, to: picked)
                    })) {
                        // The camera's current value may not be among its own
                        // choices — Canon reports "Unknown" mid-change — and a
                        // Picker with no match shows blank, so it is added.
                        if !s.choices.contains(s.value) {
                            Text(s.value.isEmpty ? "—" : s.value).tag(s.value)
                        }
                        ForEach(s.choices, id: \.self) { choice in
                            Text(choice).tag(choice)
                        }
                }
                .labelsHidden()
                .frame(width: 180)
                .disabled(c.cameraSettingBusy != nil || c.state.isSessionActive)
            }
        }
    }

    private func help(for s: CameraSetting) -> String? {
        if c.cameraSettingBusy == s.name { return "Setting the camera…" }
        if s.readOnly {
            return "The camera decides this one. Change the mode dial or the body's own menu to free it."
        }
        return nil
    }
}

private struct InterfaceCard: View {
    @ObservedObject var c: BoothController

    var body: some View {
        SectionCard(title: "Interface") {
            LabeledRow(label: "Touch controls",
                       help: "Sizes buttons, steppers, toggles and text fields for a fingertip — Apple's 44pt minimum, about 8.5mm on an iPad at 2×. Switch it on when the console is on a touch screen: an iPad used as a monitor sends its taps to macOS as ordinary clicks, so the app cannot tell on its own.") {
                Toggle("", isOn: Binding(
                    get: { c.settingsService.settings.touchControls },
                    set: { c.settingsService.settings.touchControls = $0 }))
                    .labelsHidden()
            }

            LabeledRow(label: "Framing guide",
                       help: "Marks off what the print will keep on the guest screen, dimming what gets trimmed, with thirds to frame against. The print fills each slot, so the edges of what a guest can see do not survive.") {
                Toggle("", isOn: Binding(
                    get: { c.settingsService.settings.framingGuide },
                    set: { c.settingsService.settings.framingGuide = $0 }))
                    .labelsHidden()
            }

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
                    .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 6) {
                Text("SHORTCUTS")
                    .font(.system(size: 10, weight: .semibold)).tracking(1)
                    .foregroundStyle(Palette.textDim)
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
            Text(what).font(.system(size: 11)).foregroundStyle(Palette.textDim)
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
                    .foregroundStyle(Palette.textDim)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Log folder").font(.system(size: 12, weight: .medium))
                Text(Log.shared.logDirectory.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.textDim)
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
                .font(.system(size: 11)).foregroundStyle(Palette.textDim)
        }
    }
}

/// Measured on photographic content, 3-second run-up at 10 fps, across the three
/// layouts. Animating the whole sheet costs a great deal more than a slideshow
/// of stills did — thirty frames rather than four — so these are worth knowing
/// before a night on venue wifi.
private var gifSizeNote: String {
    "One frame per photograph, so an eight-shot session runs roughly 0.4–0.6 MB at 360 px, 0.7–1.0 MB at 480 and 1.2–1.8 MB at 640."
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
