import SwiftUI
import AppKit

enum AdminTab: String, CaseIterable, Identifiable {
    case control = "Control"
    case gallery = "Sessions"
    case settings = "Settings"
    case log = "Log"
    var id: String { rawValue }

    var glyph: String {
        switch self {
        case .control:  return "slider.horizontal.3"
        case .gallery:  return "photo.stack"
        case .settings: return "gearshape"
        case .log:      return "list.bullet.rectangle"
        }
    }
}

struct AdminScreen: View {
    @ObservedObject var c: BoothController

    /// The console *renders* settings, so it has to observe the object that owns
    /// them. `BoothController` republishes only the handful it acts on, and the
    /// selected tab is not one of them — so without this a tab click changed the
    /// stored value and nothing redrew.
    ///
    /// It went unnoticed while navigation was a segmented `Picker`: AppKit moves
    /// that control's highlight itself, so it looked like it had worked and the
    /// content caught up on the next unrelated redraw. Anything drawing its own
    /// selected state, as the rail does, shows the gap immediately.
    @ObservedObject private var store: SettingsService

    init(c: BoothController) {
        _c = ObservedObject(wrappedValue: c)
        _store = ObservedObject(wrappedValue: c.settingsService)
    }

    private var tab: Binding<AdminTab> {
        Binding(get: { AdminTab(rawValue: store.settings.lastAdminTab) ?? .control },
                set: { store.settings.lastAdminTab = $0.rawValue })
    }

    var body: some View {
        GeometryReader { geo in
            // Below this the rail drops to icons: a 220pt sidebar out of an
            // 820pt window is a quarter of the console spent on navigation.
            let railExpanded = geo.size.width >= 900
            HStack(spacing: 0) {
                AdminSidebar(c: c, tab: tab, expanded: railExpanded)
                Rectangle().fill(Palette.hairline).frame(width: 1)

                VStack(spacing: 0) {
                    ContentHeader(c: c, tab: tab.wrappedValue)
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                    Group {
                        switch tab.wrappedValue {
                        case .control:  ControlTab(c: c)
                        case .gallery:  GalleryTab(c: c)
                        case .settings: SettingsTab(c: c)
                        case .log:      LogTab()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .foregroundStyle(Palette.text)
        }
        .background(Palette.canvas)
        .environment(\.colorScheme, .light)
        .environment(\.touchControls, c.settings.touchControls)
        // `controlSize` is what moves the native controls — text fields, pickers,
        // the segmented tab bar — which this app does not draw itself and so
        // cannot pad. It costs nothing when touch is off.
        .controlSize(c.settings.touchControls ? .extraLarge : .regular)
        .modifier(TouchToggleStyling(enabled: c.settings.touchControls))
        .tint(Palette.ink)
        .overlay(alignment: .bottom) {
            if let b = c.banner {
                BannerView(message: b)
                    .frame(maxWidth: 520)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: c.banner)
    }
}

// MARK: - Sidebar

/// Navigation down the left rather than tabs across the top.
///
/// On a 1180 x 820 iPad the console is wider than it is tall, so a vertical rail
/// spends the axis there is most of and gives each destination a row a thumb can
/// hit — a segmented control across the top gave every tab a 22pt-tall sliver.
/// It also puts the things an operator glances at, rather than presses — camera,
/// printer, disk — in one column instead of strung along a toolbar.
private struct AdminSidebar: View {
    @ObservedObject var c: BoothController
    @Binding var tab: AdminTab
    let expanded: Bool
    @Environment(\.touchControls) private var touch

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            wordmark
            nav
            Spacer(minLength: 12)
            if expanded { status }
            touchToggle
            boothButton
        }
        .padding(.horizontal, expanded ? 12 : 8)
        .padding(.vertical, 14)
        .frame(width: expanded ? 218 : 68, alignment: .leading)
        .background(Palette.surfaceAlt)
    }

    private var wordmark: some View {
        HStack(spacing: 8) {
            CaptureLamp(size: 8, active: c.state.isSessionActive, glow: false)
            if expanded {
                OSDLabel(text: "PHOTOBOOTH", size: 11, weight: .bold, color: Palette.ink, tracking: 0.22)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 18)
    }

    private var nav: some View {
        VStack(spacing: 4) {
            ForEach(AdminTab.allCases) { t in
                NavRow(tab: t, selected: tab == t, expanded: expanded,
                       accent: Palette.ink,
                       height: touch ? 58 : 40) { tab = t }
            }
        }
    }

    /// Small muted caption over the value it describes — the arrangement that
    /// makes a status column readable at a glance instead of parsed.
    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            StatusReadout(caption: "Camera", value: c.cameraState.label, tint: c.cameraState.tint)
            StatusReadout(caption: "Printer", value: c.printer.state.label, tint: c.printer.state.tint)
            StatusReadout(caption: "Disk", value: "\(c.storage.freeSpaceMB.asDiskSize) free",
                          tint: c.storage.freeSpaceMB < 500 ? Palette.statusWarn : Palette.textDim)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 16)
    }

    /// Touch sizing, one tap away.
    ///
    /// This lived only in Settings, which is a poor place for it: it is the
    /// difference between a console you can use with a finger and one you
    /// cannot, and an operator setting a booth up on a touch panel has no reason
    /// to go looking for it. Off by default still — an iPad used as a monitor
    /// sends taps to macOS as ordinary clicks, so the app genuinely cannot tell.
    private var touchToggle: some View {
        let on = c.settings.touchControls
        return Button {
            c.settingsService.settings.touchControls.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "hand.tap.fill" : "hand.tap")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                if expanded {
                    OSDLabel(text: on ? "Touch on" : "Touch off", size: 10,
                             weight: .semibold,
                             color: on ? Palette.paper : Palette.textDim, tracking: 0.16)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, expanded ? 10 : 0)
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .frame(height: touch ? 48 : 36)
            .background(on ? Palette.inkSoft : Palette.canvas, in: Capsule())
            .foregroundStyle(on ? Palette.paper : Palette.ink)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "Controls are sized for a fingertip" : "Size the controls for a fingertip")
        .padding(.bottom, 8)
    }

    private var boothButton: some View {
        Button {
            c.boothWindowOpen ? c.hideBooth() : c.showBooth()
        } label: {
            if expanded {
                Label(c.boothWindowOpen ? "Close Booth" : "Open Booth",
                      systemImage: c.boothWindowOpen ? "xmark.rectangle" : "rectangle.on.rectangle")
            } else {
                Image(systemName: c.boothWindowOpen ? "xmark.rectangle" : "rectangle.on.rectangle")
            }
        }
        .buttonStyle(PrimaryButtonStyle(compact: !expanded))
        .help(c.boothWindowOpen ? "Close the booth window" : "Open the booth window")
    }
}

private struct NavRow: View {
    let tab: AdminTab
    let selected: Bool
    let expanded: Bool
    let accent: Color
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // A bar rather than a filled pill: one rectangle, and it reads at
                // a glance without tinting the whole row.
                Rectangle()
                    .fill(selected ? accent : .clear)
                    .frame(width: 3, height: height * 0.5)
                Image(systemName: tab.glyph)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                if expanded {
                    OSDLabel(text: tab.rawValue, size: 11,
                             weight: selected ? .bold : .semibold,
                             color: selected ? Palette.text : Palette.textDim,
                             tracking: 0.16)
                    Spacer(minLength: 0)
                }
            }
            .padding(.trailing, expanded ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(selected ? Color.white.opacity(0.05) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(selected ? Palette.text : Palette.textDim)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.rawValue)
    }
}

private struct StatusReadout: View {
    let caption: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            OSDLabel(text: caption, size: 9, weight: .semibold, color: Palette.textDim, tracking: 0.22)
            HStack(spacing: 6) {
                StatusDot(tint: tint)
                Text(value)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint == .secondary ? Palette.textDim : tint)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Says where you are and who you are shooting, which the tab rail alone cannot.
private struct ContentHeader: View {
    @ObservedObject var c: BoothController
    let tab: AdminTab
    @Environment(\.touchControls) private var touch

    var body: some View {
        HStack(spacing: 12) {
            Text(tab.rawValue)
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 12)
            if let e = c.activeEvent {
                VStack(alignment: .trailing, spacing: 2) {
                    OSDLabel(text: "Event", size: 9, weight: .semibold, color: Palette.textDim, tracking: 0.22)
                    Text(e.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                Rectangle().fill(Palette.hairline).frame(width: 1, height: 22)
            }
            OSDLabel(text: c.state.name, size: 10, weight: .bold,
                     color: c.state.isSessionActive ? Palette.ink : Palette.textDim, tracking: 0.18)
                .padding(.leading, 2)
        }
        .padding(.horizontal, 20)
        .frame(height: touch ? 60 : 50)
    }
}

struct StatusPill: View {
    let icon: String
    let label: String
    let tint: Color
    var pulsing: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(tint: tint, pulsing: pulsing)
            OSDLabel(text: label, size: 10, color: tint == .secondary ? Palette.textDim : tint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tint == .secondary ? Palette.textDim : tint)
        .padding(.leading, 2)
        .fixedSize()
    }
}

// MARK: - Control tab

private struct ControlTab: View {
    @ObservedObject var c: BoothController

    var body: some View {
        GeometryReader { geo in
            let cols = columnCount(for: geo.size.width)
            ScrollView {
                ResponsiveColumns(count: cols, spacing: 16) {
                    [
                        // Layout and copies first: they are what changes between
                        // groups. Everything below is set once when the booth
                        // goes up and left alone.
                        AnyView(LayoutCard(c: c)),
                        AnyView(SessionCard(c: c)),
                        AnyView(EventCard(c: c)),
                        AnyView(CameraCard(c: c, live: c.livePreview)),
                        AnyView(PrinterCard(c: c)),
                        AnyView(BoothButtonCard(c: c, trigger: c.trigger)),
                        AnyView(TimingCard(c: c)),
                        AnyView(GallerySiteCard(c: c, uploader: c.uploader)),
                        AnyView(AlbumCard(c: c)),
                        AnyView(BoothWindowCard(c: c)),
                        AnyView(StorageCard(c: c))
                    ]
                }
                .frame(maxWidth: 1760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        // Measured against the content area, which is now narrower than the
        // window by the width of the rail.
        switch width {
        case ..<720:   return 1
        case ..<1180:  return 2
        default:       return 3
        }
    }
}

/// Distributes cards down N columns so rows never end up ragged.
struct ResponsiveColumns: View {
    let count: Int
    let spacing: CGFloat
    let cards: () -> [AnyView]

    init(count: Int, spacing: CGFloat, cards: @escaping () -> [AnyView]) {
        self.count = max(1, count)
        self.spacing = spacing
        self.cards = cards
    }

    var body: some View {
        let all = cards()
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<count, id: \.self) { col in
                VStack(spacing: spacing) {
                    ForEach(Array(all.enumerated()).filter { $0.offset % count == col }, id: \.offset) { item in
                        item.element
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: Camera card

private struct CameraCard: View {
    @ObservedObject var c: BoothController
    /// Observed here and nowhere else in the console, so the fifteen frames a
    /// second land on this card alone.
    @ObservedObject var live: LivePreviewSource

    var body: some View {
        SectionCard(title: "Camera",
                    accessory: AnyView(
                        HStack(spacing: 6) {
                            StatusDot(tint: c.cameraState.tint, pulsing: !c.cameraState.isReady)
                            Text(c.cameraState.label.uppercased())
                                .font(VHS.mono(10, .semibold))
                                .tracking(0.8)
                                .foregroundStyle(c.cameraState.tint)
                                .lineLimit(1)
                        })) {

            Picker("Source", selection: Binding(
                get: { c.settingsService.settings.cameraBackend },
                set: { c.settingsService.settings.cameraBackend = $0 })) {
                    ForEach(CameraBackend.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if c.settings.cameraBackend.isSimulated {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Demo source — generated frames, not real photographs.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.statusWarn)
            }

            ZStack {
                if let shot = c.shotPreview, !c.state.isSessionActive {
                    ImageView(image: shot)
                } else {
                    LivePreview(frame: live.frame,
                                mirrored: c.settings.mirrorImages,
                                placeholder: c.settings.liveViewEnabled
                                    ? "No live view — connect the camera"
                                    : "Live view is switched off")
                    // Same guide the guests get, drawn plainly: the console is
                    // for checking the crop, not for framing anyone.
                    FramingGuide(imageAspect: (live.frame?.size.width ?? 4)
                                            / max(1, live.frame?.size.height ?? 3),
                                 cellAspect: LayoutRenderer.cellAspect(for: c.settings.layout,
                                                                      settings: c.settings),
                                 cropMode: c.settings.cropMode,
                                 tint: Color(hex: c.settings.accentHex),
                                 dims: false, thirds: false)
                        .padding(8)
                }
            }
            .aspectRatio(4.0/3.0, contentMode: .fit)
            // Capped so the preview does not swallow the card when Admin drops to
            // a single column on a narrow window.
            .frame(maxWidth: .infinity, maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.hairline)
                .allowsHitTesting(false))

            if c.detectedCameras.isEmpty {
                Text(c.settings.cameraBackend == .dslr
                     ? "Nothing on USB. Set the 6D to M or Av, switch it on, and connect the cable."
                     : "No video devices found.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textDim)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(c.detectedCameras, id: \.self) { d in
                        Text(d).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.textDim)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(c.cameraState.isReady ? "Reconnect" : "Connect") { c.connectCamera() }
                    .buttonStyle(QuietButtonStyle())
                Button("Disconnect") { c.disconnectCamera() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!c.cameraState.isReady)
            }

            Button {
                c.testCapture()
            } label: {
                Label("Test Capture", systemImage: "camera.shutter.button")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!c.cameraState.isReady || c.state.isSessionActive)

            Toggle("Live view", isOn: Binding(
                get: { c.settingsService.settings.liveViewEnabled },
                set: { c.settingsService.settings.liveViewEnabled = $0 }))
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 3) {
                Toggle("Show the camera on the idle screen", isOn: Binding(
                    get: { c.settingsService.settings.idleLiveView },
                    set: { c.settingsService.settings.idleLiveView = $0 }))
                    .font(.system(size: 12))
                    .disabled(!c.settings.liveViewEnabled)
                Text(c.settings.idleLiveView
                     ? "Guests see themselves while they wait, so the booth reads as a mirror. It only runs while the booth window is open — but a DSLR held in live view all evening warms up and drains its battery, so keep it on mains power."
                     : "The idle screen stays blank until a session starts.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Toggle("Mirror images", isOn: Binding(
                    get: { c.settingsService.settings.mirrorImages },
                    set: { c.settingsService.settings.mirrorImages = $0 }))
                    .font(.system(size: 12))
                Text(c.settings.mirrorImages
                     ? "Guests see themselves as in a mirror, and the print matches."
                     : "True to the scene — any text in shot reads correctly, but the preview flips.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Session card

private struct SessionCard: View {
    @ObservedObject var c: BoothController

    var body: some View {
        SectionCard(title: "Session",
                    accessory: AnyView(
                        Text(c.state.name)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(c.state.isSessionActive ? Color.orange : .secondary)
                    )) {

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.currentSession?.id ?? "No active session")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    if let p = c.progress {
                        Text("Photo \(p.shot) of \(p.total)")
                            .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                    } else if let s = c.currentSession {
                        HStack(spacing: 5) {
                            Text("\(s.photos.count) photo(s) · \(s.layout.title)")
                            if c.settings.uploadEnabled {
                                Text("·")
                                Image(systemName: s.uploadState.glyph).font(.system(size: 9))
                                Text(s.uploadState.label)
                            }
                        }
                        .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                    }
                }
                Spacer()
            }

            // The event name is shown on the button itself so the operator can
            // never start a booking's first session against the wrong client.
            Button {
                c.state.isSessionActive ? c.cancelSession() : c.startSession()
            } label: {
                Label(c.state.isSessionActive
                      ? "Cancel Session"
                      : (c.activeEvent.map { "Start Session — \($0.name)" } ?? "Start Session"),
                      systemImage: c.state.isSessionActive ? "stop.fill" : "play.fill")
                    .lineLimit(1)
            }
            .buttonStyle(PrimaryButtonStyle(destructive: c.state.isSessionActive))
            .disabled(!c.state.isSessionActive && !c.canStartSession)

            if c.activeEvent == nil {
                Text("Pick or create an event above before starting a session.")
                    .font(.system(size: 11)).foregroundStyle(Palette.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            RetakeStrip(c: c)

            HStack(spacing: 8) {
                Button("Restart") { c.restartSession() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!c.state.isSessionActive)
                Button("Rebuild Print") { if let s = c.currentSession { c.rebuildPrint(for: s) } }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(c.currentSession?.photos.isEmpty ?? true)
            }

            HStack(spacing: 8) {
                Button("Print Session") { c.printCurrentSession() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(c.currentSession?.printFileName == nil || c.isPrintBusy)
                Button("Return to Idle") { c.returnToIdle() }
                    .buttonStyle(QuietButtonStyle())
            }

            // The sheet has not gone to the printer yet — the operator should
            // know that "Return to Idle" here means nobody gets a print.
            if c.pendingPrint {
                Label("Print waiting for the button press — \"Print Session\" sends it now.",
                      systemImage: "printer.dotmatrix")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if c.settings.uploadEnabled, let s = c.currentSession, s.uploadState != .uploaded {
                Button("Upload to Gallery") { c.queueUpload(s) }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(s.printFileName == nil && s.photos.isEmpty)
            }

            if let s = c.currentSession, let err = s.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.statusBad)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let s = c.currentSession { SessionQRRow(c: c, rec: s) }
        }
    }
}

// MARK: Retake strip

/// Every photograph in the session carries a number, and here those numbers are
/// buttons. Clicking one marks that shot to be taken again — during the run, or
/// afterwards from the finish screen, which is when a guest usually says they
/// blinked. The strip is the whole feature: no menus, no dialogs, one click.
private struct RetakeStrip: View {
    @ObservedObject var c: BoothController

    var body: some View {
        let total = c.shotCount
        let taken = Set((c.currentSession?.photos ?? []).map(\.index))

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                OSDLabel(text: "Retake", size: 10, color: Palette.textDim, tracking: 0.22)
                Spacer(minLength: 6)
                if !c.retakeQueue.isEmpty {
                    OSDLabel(text: "\(c.retakeQueue.count) queued",
                             size: 10, color: Palette.ember, tracking: 0.16)
                }
            }

            // Wraps rather than scrolls: eight numbers must stay clickable in the
            // narrowest console window.
            FlowRow(spacing: 6) {
                (1...max(1, total)).map { n in
                    AnyView(RetakeNumber(number: n,
                                         taken: taken.contains(n),
                                         queued: c.retakeQueue.contains(n),
                                         shooting: c.progress?.shot == n && c.state.isSessionActive,
                                         enabled: enabled(n, taken: taken),
                                         action: { c.toggleRetake(shot: n) }))
                }
            }

            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func enabled(_ n: Int, taken: Set<Int>) -> Bool {
        if c.state.isSessionActive { return taken.contains(n) || c.progress?.shot == n }
        return c.canRetake && taken.contains(n)
    }

    private var hint: String {
        if c.retakeQueue.isEmpty {
            if c.state.isSessionActive {
                return "Click a number to re-shoot that photo. Queued shots are taken after the last one."
            }
            guard let s = c.currentSession, !s.photos.isEmpty else {
                return "Numbers become clickable once a session has photographs."
            }
            return "Click a number to re-shoot it — the print is rebuilt and sent again."
        }
        let list = c.retakeQueue.sorted().map(String.init).joined(separator: ", ")
        return "Photo \(list) will be taken again. Click the number again to keep the original."
    }
}

private struct RetakeNumber: View {
    let number: Int
    let taken: Bool
    let queued: Bool
    let shooting: Bool
    let enabled: Bool
    let action: () -> Void

    @Environment(\.touchControls) private var touch

    var body: some View {
        Button(action: action) {
            Text("\(number)")
                .font(VHS.mono(touch ? 17 : 12, .bold))
                .frame(width: touch ? 60 : 30, height: touch ? 56 : 28)
                .background(background)
                .foregroundStyle(foreground)
                .overlay(Rectangle().stroke(border, lineWidth: 1).allowsHitTesting(false))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(helpText)
    }

    private var background: Color {
        if queued { return Palette.statusBad }
        if shooting { return Palette.statusWarn.opacity(0.30) }
        return Color.white.opacity(taken ? 0.07 : 0.02)
    }

    private var foreground: Color {
        if queued { return Palette.paper }
        if !enabled { return Palette.textDim.opacity(0.5) }
        return taken ? Palette.text : Palette.textDim
    }

    private var border: Color {
        if queued { return Palette.statusBad }
        if shooting { return Palette.statusWarn }
        return Palette.text.opacity(taken ? 0.28 : 0.10)
    }

    private var helpText: String {
        if queued { return "Photo \(number) is queued for a retake — click to keep the original" }
        if !taken { return "Photo \(number) has not been taken yet" }
        return "Re-shoot photo \(number)"
    }
}

/// Wraps its children onto as many rows as the width needs.
struct FlowRow: View {
    var spacing: CGFloat = 6
    var perRow: Int = 8
    let items: () -> [AnyView]

    init(spacing: CGFloat = 6, perRow: Int = 8, items: @escaping () -> [AnyView]) {
        self.spacing = spacing
        self.perRow = max(1, perRow)
        self.items = items
    }

    var body: some View {
        let all = items()
        // Chunking is simpler than a full flow layout and gives the same result
        // for the handful of numbers a layout or a copy count can have.
        let rows = stride(from: 0, to: all.count, by: perRow).map { start in
            Array(start..<min(start + perRow, all.count))
        }
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { row in
                HStack(spacing: spacing) {
                    ForEach(row.element, id: \.self) { i in all[i] }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: Session QR

/// The link guests scan. Shown as soon as there is a session to point at, so the
/// operator can hold the console up to a phone if the booth screen is busy.
private struct SessionQRRow: View {
    @ObservedObject var c: BoothController
    let rec: SessionRecord

    var body: some View {
        if let url = c.galleryURL(for: rec) {
            HStack(alignment: .top, spacing: 12) {
                if let qr = QRCode.image(for: url.absoluteString, minimumSide: 220) {
                    Image(nsImage: qr)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 72, height: 72)
                        .padding(4)
                        .background(Color.white)
                }
                VStack(alignment: .leading, spacing: 6) {
                    OSDLabel(text: "Album link", size: 10, color: Palette.textDim, tracking: 0.22)
                    Text(url.absoluteString)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.textDim)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Button("Copy Link") { c.copyGalleryLink(for: rec) }
                            .buttonStyle(QuietButtonStyle())
                        Button("Open") { NSWorkspace.shared.open(url) }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
            }
        } else {
            Text("Set the gallery site address in Settings to hand guests a QR code.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Booth button card

/// The physical start button.
///
/// Photobooth buttons are USB devices that pretend to be a keyboard, so this is a
/// key assignment rather than a device picker — which is what lets any button the
/// operator buys work. Learn captures whatever the button actually sends.
private struct BoothButtonCard: View {
    @ObservedObject var c: BoothController
    @ObservedObject var trigger: TriggerService

    private func bind<T>(_ path: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { c.settingsService.settings[keyPath: path] },
                set: { c.settingsService.settings[keyPath: path] = $0 })
    }

    var body: some View {
        SectionCard(title: "Booth Button",
                    accessory: AnyView(
                        StatusPill(icon: "button.programmable",
                                   label: trigger.access.label,
                                   tint: c.settings.triggerEnabled ? trigger.access.tint : Palette.textDim)
                    )) {

            Toggle("Start with a USB button", isOn: bind(\.triggerEnabled))
                .font(.system(size: 12))

            LabeledRow(label: "Assigned key",
                       help: "Plug the button in and press Learn, then press the button itself. Most send Return or keypad Enter.") {
                HStack(spacing: 8) {
                    Text(trigger.isLearning ? "Press the button…" : trigger.keyLabel)
                        .font(VHS.mono(11, .bold))
                        .foregroundStyle(trigger.isLearning ? Palette.statusWarn : Palette.text)
                        .frame(minWidth: 96, alignment: .trailing)
                    Button(trigger.isLearning ? "Cancel" : "Learn") {
                        if trigger.isLearning {
                            trigger.cancelLearning()
                        } else {
                            trigger.learn { code, label in
                                c.settingsService.settings.triggerKeyCode = Int(code)
                                c.show(.info, "Booth button set to \(label).")
                            }
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .frame(width: 84)
                }
            }
            .disabled(!c.settings.triggerEnabled)

            Toggle("Works even when Photobooth is not in front", isOn: bind(\.triggerGlobal))
                .font(.system(size: 12))
                .disabled(!c.settings.triggerEnabled)

            // The honest bit: macOS will not let any app watch the keyboard
            // system-wide without this, so say so and offer the way to fix it
            // rather than silently doing nothing.
            if c.settings.triggerEnabled && c.settings.triggerGlobal && trigger.access == .denied {
                VStack(alignment: .leading, spacing: 7) {
                    Text("macOS needs Input Monitoring permission before the button can work while another app, or the pointer, is elsewhere. Until then it only works when a Photobooth window is in front.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.statusWarn)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Grant Access") { trigger.requestAccess() }
                            .buttonStyle(PrimaryButtonStyle(tint: Palette.statusWarn, compact: true))
                        Button("Open Settings") { trigger.openInputMonitoringSettings() }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
            }

            LabeledRow(label: "Ignore repeats within",
                       help: "Buttons bounce and guests mash — one press must not start two sessions.") {
                IntStepper(value: bind(\.triggerDebounceMs), range: 100...3000, suffix: "ms")
            }
            .disabled(!c.settings.triggerEnabled)

            Divider().overlay(Palette.hairline)

            Toggle("Wait for a button press after each session", isOn: bind(\.holdFinishUntilPress))
                .font(.system(size: 12))
            Text(c.settings.holdFinishUntilPress
                 ? (c.settings.autoPrint
                    ? "The finish screen stays up — with the QR code — until somebody presses the button. That press also releases the print, then starts the booth over."
                    : "The finish screen stays up — with the QR code — until somebody presses the button.")
                 : "The finish screen clears itself after the time set in Timing.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)

            if c.settings.holdFinishUntilPress {
                LabeledRow(label: "Give up waiting after") {
                    DoubleStepper(value: bind(\.finishHoldTimeoutSeconds),
                                  range: 0...900, step: 30, suffix: "s")
                }
                Text(c.settings.finishHoldTimeoutSeconds == 0
                     ? "Never — the booth waits indefinitely."
                     : (c.settings.autoPrint
                        ? "A safety net: an unattended booth still resets itself. A group that walks off without pressing is not printed — send it later from Gallery."
                        : "A safety net: an unattended booth still resets itself."))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textDim)
            }

            HStack(spacing: 8) {
                Button("Test Press") { c.triggerPressed() }
                    .buttonStyle(QuietButtonStyle())
                Text(trigger.lastPressAt.map { "Last press \($0.clockStamp) · \(trigger.pressCount) total" }
                     ?? "No press seen yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textDim)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: Timing card

private struct TimingCard: View {
    @ObservedObject var c: BoothController

    var body: some View {
        SectionCard(title: "Timing") {
            LabeledRow(label: "Countdown", help: "Seconds shown before each shot.") {
                IntStepper(value: Binding(
                    get: { c.settingsService.settings.countdownSeconds },
                    set: { c.settingsService.settings.countdownSeconds = $0 }),
                    range: 1...10, suffix: "s")
            }
            LabeledRow(label: "Photo preview", help: "How long the captured photo stays on screen.") {
                DoubleStepper(value: Binding(
                    get: { c.settingsService.settings.previewSeconds },
                    set: { c.settingsService.settings.previewSeconds = $0 }),
                    range: 0...15, step: 0.5, suffix: "s")
            }
            LabeledRow(label: "Shot interval", help: "Pause between one shot ending and the next countdown.") {
                DoubleStepper(value: Binding(
                    get: { c.settingsService.settings.shotIntervalSeconds },
                    set: { c.settingsService.settings.shotIntervalSeconds = $0 }),
                    range: 0...15, step: 0.5, suffix: "s")
            }
            LabeledRow(label: "Finish screen", help: "How long the print is shown before returning to idle.") {
                DoubleStepper(value: Binding(
                    get: { c.settingsService.settings.completeScreenSeconds },
                    set: { c.settingsService.settings.completeScreenSeconds = $0 }),
                    range: 1...30, step: 1, suffix: "s")
            }

            Divider().opacity(0.4)

            Text("A \(c.settings.layout.photoCount)-shot session takes about \(estimate) seconds.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textDim)
        }
    }

    private var estimate: Int {
        let s = c.settings
        let n = Double(s.layout.photoCount)
        let per = Double(s.countdownSeconds) + 1.2 + s.previewSeconds
        return Int(1.0 + n * per + (n - 1) * s.shotIntervalSeconds)
    }
}

struct IntStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix: String = ""
    @Environment(\.touchControls) private var touch

    var body: some View {
        HStack(spacing: touch ? 8 : 6) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: touch ? 68 : 52)
                .multilineTextAlignment(.trailing)
            if !suffix.isEmpty {
                Text(suffix).font(.system(size: 11)).foregroundStyle(Palette.textDim)
            }
            if touch {
                // The native stepper is two 11pt arrows stacked — a target no
                // fingertip can pick between. Two square buttons instead.
                StepPad(symbol: "minus") { value = max(range.lowerBound, value - 1) }
                    .disabled(value <= range.lowerBound)
                StepPad(symbol: "plus") { value = min(range.upperBound, value + 1) }
                    .disabled(value >= range.upperBound)
            } else {
                Stepper("", value: $value, in: range).labelsHidden()
            }
        }
        .onChange(of: value) { _, v in
            if v < range.lowerBound { value = range.lowerBound }
            if v > range.upperBound { value = range.upperBound }
        }
    }
}

struct DoubleStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.5
    var suffix: String = ""
    @Environment(\.touchControls) private var touch

    var body: some View {
        HStack(spacing: touch ? 8 : 6) {
            TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: touch ? 74 : 58)
                .multilineTextAlignment(.trailing)
            if !suffix.isEmpty {
                Text(suffix).font(.system(size: 11)).foregroundStyle(Palette.textDim)
            }
            if touch {
                StepPad(symbol: "minus") { value = max(range.lowerBound, value - step) }
                    .disabled(value <= range.lowerBound)
                StepPad(symbol: "plus") { value = min(range.upperBound, value + step) }
                    .disabled(value >= range.upperBound)
            } else {
                Stepper("", value: $value, in: range, step: step).labelsHidden()
            }
        }
        .onChange(of: value) { _, v in
            if v < range.lowerBound { value = range.lowerBound }
            if v > range.upperBound { value = range.upperBound }
        }
    }
}

/// One square of a touch stepper. 44 × 44, which is the smallest target a
/// fingertip hits reliably — about 8.5mm on an iPad at 2×.
private struct StepPad: View {
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.06))
                .foregroundStyle(isEnabled ? Palette.text : Palette.textDim.opacity(0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Layout card

private struct LayoutCard: View {
    @ObservedObject var c: BoothController

    var body: some View {
        SectionCard(title: "Print Layout") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) { choices }
                VStack(alignment: .leading, spacing: 10) { choicesWide }
            }

            Divider().opacity(0.4)

            CopiesPicker(c: c)
            Toggle("Print automatically when a session finishes", isOn: Binding(
                get: { c.settingsService.settings.autoPrint },
                set: { c.settingsService.settings.autoPrint = $0 }))
                .font(.system(size: 12))
        }
    }

    @ViewBuilder private var choices: some View {
        ForEach(PrintLayout.allCases) { layout in
            LayoutChoice(layout: layout, c: c, showsSubtitle: false)
        }
    }

    @ViewBuilder private var choicesWide: some View {
        ForEach(PrintLayout.allCases) { layout in
            LayoutChoice(layout: layout, c: c, showsSubtitle: true)
        }
    }
}

/// Copies as ten buttons rather than a field and a stepper.
///
/// The value only ever runs 1–10, so there is nothing worth typing, and on a
/// touch screen a text field means the on-screen keyboard covering the panel to
/// enter a single digit. One tap sets it.
private struct CopiesPicker: View {
    @ObservedObject var c: BoothController
    @Environment(\.touchControls) private var touch

    var body: some View {
        VStack(alignment: .leading, spacing: touch ? 10 : 5) {
            HStack(spacing: 8) {
                Text("Copies").font(.system(size: touch ? 14 : 12, weight: .medium))
                Spacer(minLength: 8)
                // The chosen number restated, so the answer is legible without
                // hunting for which of ten buttons is filled.
                Text("\(c.settings.copies) per session")
                    .font(.system(size: touch ? 12 : 11))
                    .foregroundStyle(Palette.textDim)
            }

            FlowRow(spacing: touch ? 8 : 6, perRow: 5) {
                (1...10).map { n in
                    AnyView(CopiesNumber(
                        number: n,
                        selected: c.settings.copies == n,
                        side: touch ? 56 : 32,
                        accent: Palette.ink,
                        action: { c.settingsService.settings.copies = n }))
                }
            }

        }
    }
}

private struct CopiesNumber: View {
    let number: Int
    let selected: Bool
    let side: CGFloat
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(number)")
                .font(VHS.mono(side > 40 ? 16 : 12, .bold))
                .frame(width: side, height: side)
                .background(selected ? accent : Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(selected ? Palette.paper : Palette.text)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(selected ? accent : Palette.hairline, lineWidth: 1)
                    .allowsHitTesting(false))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LayoutChoice: View {
    let layout: PrintLayout
    @ObservedObject var c: BoothController
    let showsSubtitle: Bool
    @Environment(\.touchControls) private var touch

    var body: some View {
        let selected = c.settings.layout == layout
        let accent = Palette.ink

        Button {
            c.settingsService.settings.layout = layout
        } label: {
            Group {
                if showsSubtitle {
                    HStack(alignment: .center, spacing: touch ? 14 : 10) {
                        schematic.frame(width: touch ? 72 : 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(layout.title)
                                .font(.system(size: touch ? 14 : 12, weight: .semibold))
                            Text("\(layout.photoCount) photos · \(layout.subtitle)")
                                .font(.system(size: touch ? 12 : 11))
                                .foregroundStyle(Palette.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        // A tick, not just a heavier border: at a glance across a
                        // room the border weight alone is not a difference.
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: touch ? 22 : 17))
                            .foregroundStyle(selected ? Palette.ink : Palette.hairline)
                    }
                } else {
                    VStack(spacing: 7) {
                        schematic
                        Text(layout.title)
                            .font(.system(size: 11, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(touch ? 18 : 9)
            .frame(maxWidth: .infinity)
            .background(selected ? accent.opacity(0.14) : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? accent : Palette.hairline, lineWidth: selected ? 2 : 1)
                .allowsHitTesting(false))
            // Last, so the tappable area is the whole tile including its
            // padding and border rather than just the text and thumbnail.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var schematic: some View {
        Group {
            if let img = LayoutRenderer.schematic(for: layout, settings: c.settings, width: 200) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.2)).aspectRatio(2.0/3.0, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.hairline)
            .allowsHitTesting(false))
    }
}

// MARK: Printer card

private struct PrinterCard: View {
    @ObservedObject var c: BoothController

    var body: some View {
        SectionCard(title: "Printer",
                    accessory: AnyView(
                        HStack(spacing: 6) {
                            StatusDot(tint: c.printer.state.tint)
                            Text(c.printer.state.label.uppercased())
                                .font(VHS.mono(10, .semibold))
                                .tracking(0.8)
                                .foregroundStyle(c.printer.state.tint)
                                .lineLimit(1)
                        })) {

            Picker("Destination", selection: Binding(
                get: { c.settingsService.settings.printerName },
                set: { c.settingsService.settings.printerName = $0 })) {
                    Text("System default (\(c.printer.systemDefault))").tag("")
                    ForEach(c.printer.availablePrinters, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()

            Toggle("Borderless (Postcard.Fullbleed)", isOn: Binding(
                get: { c.settingsService.settings.borderless },
                set: { c.settingsService.settings.borderless = $0 }))
                .font(.system(size: 12))

            HStack {
                Text("Queue")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(c.printer.queueDepth) job(s)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(c.printer.queueDepth > 0 ? Palette.statusWarn : .secondary)
            }

            if !c.printer.jobs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(c.printer.jobs.suffix(4).reversed()) { j in
                        HStack(spacing: 6) {
                            Image(systemName: j.done ? "checkmark.circle.fill"
                                  : (j.failed ? "xmark.circle.fill" : "arrow.triangle.2.circlepath"))
                                .font(.system(size: 10))
                                .foregroundStyle(j.done ? Palette.statusOK : (j.failed ? .red : Palette.statusWarn))
                            Text(j.id).font(.system(size: 10, design: .monospaced))
                            Spacer()
                            Text(j.submittedAt.clockStamp)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.textDim)
                        }
                    }
                }
                .padding(8)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            }

            Button {
                c.testPrint()
            } label: {
                Label("Test Print", systemImage: "printer.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!c.printer.state.isReady || c.isPrintBusy)

            HStack(spacing: 8) {
                Button("Refresh") { c.printer.refresh() }
                    .buttonStyle(QuietButtonStyle())
                Button("Cancel Queue") { c.printer.cancelAll() }
                    .buttonStyle(QuietButtonStyle(destructive: true))
                    .disabled(c.printer.queueDepth == 0)
            }

            Text("Prints are sent as flattened \(c.settings.dpi) DPI 4×6 JPEGs through the macOS print system.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Booth window card

private struct BoothWindowCard: View {
    @ObservedObject var c: BoothController
    @State private var screens: [NSScreen] = NSScreen.screens

    var body: some View {
        SectionCard(title: "Booth Window",
                    accessory: AnyView(
                        HStack(spacing: 6) {
                            StatusDot(tint: c.boothWindowOpen ? Palette.statusOK : .secondary)
                            Text(c.boothWindowOpen ? "Open" : "Closed".uppercased())
                                .font(VHS.mono(10, .semibold))
                                .tracking(0.8)
                                .foregroundStyle(c.boothWindowOpen ? Palette.statusOK : .secondary)
                        })) {

            Text("The guest screen is its own window, so it can live full screen on the booth display while you keep this console on the laptop.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Display").font(.system(size: 12, weight: .medium))
                Picker("", selection: Binding(
                    get: { c.settingsService.settings.boothDisplayID },
                    set: { c.settingsService.settings.boothDisplayID = $0 })) {
                        Text("Automatic (second display if present)").tag("")
                        ForEach(screens, id: \.displayIDString) { s in
                            Text(s.boothLabel).tag(s.displayIDString)
                        }
                }
                .labelsHidden()
            }

            Toggle("Full screen when opened", isOn: Binding(
                get: { c.settingsService.settings.fullScreenOnLaunch },
                set: { c.settingsService.settings.fullScreenOnLaunch = $0 }))
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Light rendering", isOn: Binding(
                    get: { c.settingsService.settings.lightRendering },
                    set: { c.settingsService.settings.lightRendering = $0 }))
                    .font(.system(size: 12))
                Text("For a booth screen carried over USB, wireless or screen sharing. Stops the drifting tracking band, the blinking lamps and the colour fringing, so the guest screen only redraws when something actually changes. Leave off on a directly-attached monitor.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Open the booth window at launch", isOn: Binding(
                get: { c.settingsService.settings.openBoothOnLaunch },
                set: { c.settingsService.settings.openBoothOnLaunch = $0 }))
                .font(.system(size: 12))

            Button {
                c.boothWindowOpen ? c.hideBooth() : c.showBooth()
            } label: {
                Label(c.boothWindowOpen ? "Close Booth Window" : "Open Booth Window",
                      systemImage: c.boothWindowOpen ? "xmark.rectangle" : "rectangle.on.rectangle")
            }
            .buttonStyle(PrimaryButtonStyle())

            if c.boothWindowOpen {
                HStack(spacing: 8) {
                    Button("Bring Forward") { c.showBooth() }
                        .buttonStyle(QuietButtonStyle())
                    Button("Windowed") { c.showBooth(fullScreen: false) }
                        .buttonStyle(QuietButtonStyle())
                }
            }

            Text(screens.count > 1
                 ? "\(screens.count) displays detected."
                 : "One display detected — the booth window will cover this screen.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textDim)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }
}

// MARK: Storage card

private struct StorageCard: View {
    @ObservedObject var c: BoothController

    var body: some View {
        SectionCard(title: "Storage") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Save location")
                    .font(.system(size: 12, weight: .medium))
                Text(c.storage.root.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.textDim)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button("Choose…") { chooseFolder() }
                    .buttonStyle(QuietButtonStyle())
                Button("Open in Finder") {
                    NSWorkspace.shared.open(c.storage.root)
                }
                .buttonStyle(QuietButtonStyle())
            }

            HStack {
                Text("Events on disk").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(c.storage.events.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.textDim)
            }

            Divider().opacity(0.4)

            HStack {
                Text("Sessions on disk").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(c.storage.sessions.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.textDim)
            }
            HStack {
                Text("Free space").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(c.storage.freeSpaceMB.asDiskSize)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(c.storage.freeSpaceMB < 500 ? Palette.statusWarn : .secondary)
            }

            Toggle("Keep originals on the camera card", isOn: Binding(
                get: { c.settingsService.settings.keepOriginalsOnCard },
                set: { c.settingsService.settings.keepOriginalsOnCard = $0 }))
                .font(.system(size: 12))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.directoryURL = c.storage.root
        if panel.runModal() == .OK, let url = panel.url {
            c.settingsService.settings.rootPathOverride = url.path
            c.storage.reload()
        }
    }
}

// MARK: - Log tab

private struct LogTab: View {
    @ObservedObject var log = Log.shared
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Filter…", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
                Text("\(shown.count) line(s)")
                    .font(.system(size: 11)).foregroundStyle(Palette.textDim)
                Button("Reveal Log File") {
                    NSWorkspace.shared.activateFileViewerSelecting([log.todayLogURL()])
                }
                .buttonStyle(.bordered)
            }
            .padding(12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { e in
                            HStack(alignment: .top, spacing: 8) {
                                Text(e.at.clockStamp)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Palette.textDim.opacity(0.65))
                                Text(e.level.rawValue)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(e.tint)
                                    .frame(width: 40, alignment: .leading)
                                Text(e.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .id(e.id)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: log.entries.count) { _, _ in
                    if let last = shown.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private var shown: [LogEntry] {
        guard !filter.isEmpty else { return log.entries }
        return log.entries.filter { $0.message.localizedCaseInsensitiveContains(filter) }
    }
}
