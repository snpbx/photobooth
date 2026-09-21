import AppKit
import SwiftUI

/// A hosting view that lets the very first click through to what is under it.
///
/// macOS spends the first click on an inactive window activating that window and
/// does not deliver it to the control beneath the pointer. At a desk this is
/// barely noticeable. On a booth console it means every button has to be pressed
/// twice whenever focus has wandered — to the guest window, to whatever is
/// driving a second display, to anything at all — which reads as the console
/// ignoring presses at random, with a mouse exactly as much as with a finger.
///
/// The booth is a two-window app on two screens, so focus wanders constantly.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let shared = AppDelegate()

    private var adminWindow: NSWindow!
    private var boothWindow: NSWindow?
    private var editorWindow: NSWindow?
    private var controller: BoothController!

    private enum WindowRole: String { case admin, booth, editor }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = BoothController()
        controller.openBoothWindow  = { [weak self] fs in self?.openBooth(fullScreen: fs) }
        controller.closeBoothWindow = { [weak self] in self?.closeBooth() }
        controller.focusAdminWindow = { [weak self] in self?.focusAdmin() }
        controller.openPrintEditor = { [weak self] in self?.openEditor() }

        buildAdminWindow()
        buildMenu()
        installKeyMonitor()

        NSApp.activate(ignoringOtherApps: true)
        if controller.settings.openBoothOnLaunch {
            openBooth(fullScreen: controller.settings.fullScreenOnLaunch)
        }
    }

    // MARK: - Admin window

    private func buildAdminWindow() {
        // 1360 × 880 is the console at its most comfortable, not a requirement.
        // The booth's own monitor decides: see `NSScreen.fitting`.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let w = NSWindow(
            contentRect: NSRect(origin: .zero,
                                size: screen.fitting(NSSize(width: 1360, height: 880), margin: 20)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "Photobooth — Admin"
        w.identifier = NSUserInterfaceItemIdentifier(WindowRole.admin.rawValue)
        w.minSize = screen.fitting(NSSize(width: 680, height: 480))
        w.setFrameAutosaveName("PhotoboothAdminWindow")
        // The autosaved frame was recorded on whatever display was attached last
        // time, which may have been larger than this one.
        w.setContentSize(screen.fitting(w.contentRect(forFrameRect: w.frame).size, margin: 20))
        w.center()
        w.delegate = self
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.contentView = FirstMouseHostingView(rootView: AdminRootView(c: controller))
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        adminWindow = w
        controller.noteAdminWindow(visible: true)
    }

    private func focusAdmin() {
        if !adminWindow.isVisible { adminWindow.makeKeyAndOrderFront(nil) }
        adminWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.noteAdminWindow(visible: true)
    }

    // MARK: - Print editor

    /// Its own window, not another Admin tab. Laying out a sheet happens once
    /// before an event rather than between groups, and it wants the room.
    private func openEditor() {
        if let existing = editorWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let screen = adminWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let w = NSWindow(
            contentRect: NSRect(origin: .zero,
                                size: screen.fitting(NSSize(width: 1180, height: 820), margin: 20)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "Print Layout"
        w.identifier = NSUserInterfaceItemIdentifier(WindowRole.editor.rawValue)
        w.minSize = screen.fitting(NSSize(width: 900, height: 600))
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.contentView = FirstMouseHostingView(
            rootView: PrintEditorView(c: controller, store: controller.templates))
        w.center()
        editorWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Booth window

    /// Placed on the operator's chosen display, falling back to a screen the
    /// Admin window is not already occupying — the common two-monitor setup.
    private func boothScreen() -> NSScreen {
        let screens = NSScreen.screens
        let wanted = controller.settings.boothDisplayID
        if !wanted.isEmpty,
           let match = screens.first(where: { $0.displayIDString == wanted }) {
            return match
        }
        if screens.count > 1, let adminScreen = adminWindow.screen,
           let other = screens.first(where: { $0 !== adminScreen }) {
            return other
        }
        return screens.first ?? NSScreen.main!
    }

    private func openBooth(fullScreen: Bool) {
        if let existing = boothWindow {
            moveBooth(existing, to: boothScreen(), fullScreen: fullScreen)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let screen = boothScreen()
        let w = NSWindow(
            contentRect: screen.visibleFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false, screen: screen)
        w.title = "Photobooth"
        w.identifier = NSUserInterfaceItemIdentifier(WindowRole.booth.rawValue)
        w.minSize = screen.fitting(NSSize(width: 640, height: 480))
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.backgroundColor = NSColor(red: 0.043, green: 0.047, blue: 0.058, alpha: 1)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.contentView = FirstMouseHostingView(rootView: BoothRootView(c: controller))
        boothWindow = w

        moveBooth(w, to: screen, fullScreen: fullScreen)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.noteBoothWindow(open: true)
    }

    private func moveBooth(_ w: NSWindow, to screen: NSScreen, fullScreen: Bool) {
        let isFull = w.styleMask.contains(.fullScreen)
        if isFull && !fullScreen {
            w.toggleFullScreen(nil)
            return
        }
        if !isFull {
            w.setFrame(screen.visibleFrame, display: true)
            if fullScreen { w.toggleFullScreen(nil) }
        }
    }

    private func closeBooth() {
        guard let w = boothWindow else { return }
        if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        w.orderOut(nil)
        w.close()
        boothWindow = nil
        controller.noteBoothWindow(open: false)
        focusAdmin()
    }

    private func toggleBooth() {
        boothWindow == nil ? openBooth(fullScreen: controller.settings.fullScreenOnLaunch) : closeBooth()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        switch role(of: w) {
        case .booth:
            boothWindow = nil
            controller.noteBoothWindow(open: false)
        case .admin:
            controller.noteAdminWindow(visible: false)
        case .editor:
            editorWindow = nil
        case nil:
            break
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, role(of: w) == .admin else { return }
        controller.noteAdminWindow(visible: true)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, role(of: w) == .admin else { return }
        controller.noteAdminWindow(visible: false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, role(of: w) == .admin else { return }
        controller.noteAdminWindow(visible: true)
    }

    private func role(of w: NSWindow) -> WindowRole? {
        guard let id = w.identifier?.rawValue else { return nil }
        return WindowRole(rawValue: id)
    }

    // MARK: - Lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { focusAdmin() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.state.isSessionActive else {
            controller.settingsService.saveNow()
            Log.shared.info("Photobooth quit")
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "A session is still running."
        alert.informativeText = "Photographs already taken are saved. Quit anyway?"
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Stay")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            controller.cancelSession()
            controller.settingsService.saveNow()
            Log.shared.warn("Quit during an active session")
            return .terminateNow
        }
        return .terminateCancel
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Unpack to value types: NSEvent itself is not Sendable.
            let code = event.keyCode
            let cmd = event.modifierFlags.contains(.command)
            let chars = event.charactersIgnoringModifiers?.lowercased()
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated {
                self.handle(keyCode: code, command: cmd, characters: chars)
            }
            return consumed ? nil : event
        }
    }

    private func handle(keyCode: UInt16, command: Bool, characters: String?) -> Bool {
        let inBooth = NSApp.keyWindow.flatMap(role(of:)) == .booth

        if command, let ch = characters {
            switch ch {
            case "b": toggleBooth(); return true
            case ".": controller.cancelSession(); return true
            default: break
            }
        }

        guard inBooth else { return false }

        switch keyCode {
        case 53:                        // ESC — ask the booth window to reveal Admin
            NotificationCenter.default.post(name: .boothRequestedAdmin, object: nil)
            return true
        case 49, 36, 76:                // space, return, keypad enter
            // Routed through the same path as the physical button, so the
            // keyboard and the USB button can never disagree about what a press
            // means at a given point in the session.
            controller.triggerPressed()
            return true
        default:
            return false
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        add(appMenu, "About Photobooth", #selector(about), "", [])
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Photobooth", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Photobooth", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let sessionItem = NSMenuItem()
        let sessionMenu = NSMenu(title: "Session")
        add(sessionMenu, "Start Session", #selector(startSession), "\r", [.command])
        add(sessionMenu, "Cancel Session", #selector(cancelSession), ".", [.command])
        sessionMenu.addItem(.separator())
        add(sessionMenu, "Retake Current Photo", #selector(retake), "r", [.command, .shift])
        add(sessionMenu, "Return to Idle", #selector(idle), "i", [.command, .shift])
        sessionItem.submenu = sessionMenu
        main.addItem(sessionItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        add(windowMenu, "Admin Console", #selector(showAdmin), "1", [.command])
        add(windowMenu, "Booth Window", #selector(showBooth), "2", [.command])
        add(windowMenu, "Print Layout Editor", #selector(showEditor), "3", [.command])
        windowMenu.addItem(.separator())
        add(windowMenu, "Toggle Booth Window", #selector(toggleBoothMenu), "b", [.command])
        add(windowMenu, "Close Booth Window", #selector(closeBoothMenu), "w", [.command, .shift])
        windowMenu.addItem(.separator())
        let fs = NSMenuItem(title: "Toggle Full Screen",
                            action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(fs)
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let printItem = NSMenuItem()
        let printMenu = NSMenu(title: "Print")
        add(printMenu, "Test Print", #selector(testPrint), "p", [.command, .shift])
        add(printMenu, "Print Current Session", #selector(printSession), "p", [.command])
        printMenu.addItem(.separator())
        add(printMenu, "Open Sessions Folder", #selector(openFolder), "o", [.command, .shift])
        printItem.submenu = printMenu
        main.addItem(printItem)

        NSApp.mainMenu = main
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector,
                     _ key: String, _ mods: NSEvent.ModifierFlags) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        menu.addItem(item)
    }

    @objc private func startSession()   { controller.startSession() }
    @objc private func cancelSession()  { controller.cancelSession() }
    @objc private func retake()         { controller.retakeCurrentPhoto() }
    @objc private func idle()           { controller.returnToIdle() }
    @objc private func showAdmin()      { focusAdmin() }
    @objc private func showBooth()      { openBooth(fullScreen: controller.settings.fullScreenOnLaunch) }
    @objc private func showEditor()     { openEditor() }
    @objc private func toggleBoothMenu(){ toggleBooth() }
    @objc private func closeBoothMenu() { closeBooth() }
    @objc private func testPrint()      { controller.testPrint() }
    @objc private func printSession()   { controller.printCurrentSession() }
    @objc private func openFolder()     { NSWorkspace.shared.open(controller.storage.eventsRoot) }

    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "Photobooth \(Bundle.main.appVersion)"
        alert.informativeText = """
        Canon EOS DSLR + SELPHY CP1500 photobooth for macOS.

        Camera capture uses libgphoto2 (bundled).
        Printing goes through the macOS print system.

        Sessions: \(controller.storage.root.path)
        Logs: \(Log.shared.logDirectory.path)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// libgphoto2 resolves its camera/port drivers from these env vars. They must be
/// set before the first gphoto call, and they point at the copies inside the app
/// bundle so the DMG works on a Mac without Homebrew.
func pointGPhotoAtBundledDrivers() {
    let res = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
    let cam = res.appendingPathComponent("camlibs")
    let io  = res.appendingPathComponent("iolibs")
    if FileManager.default.fileExists(atPath: cam.path) { setenv("CAMLIBS", cam.path, 1) }
    if FileManager.default.fileExists(atPath: io.path)  { setenv("IOLIBS",  io.path,  1) }
}

pointGPhotoAtBundledDrivers()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = AppDelegate.shared
    app.setActivationPolicy(.regular)
    app.run()
}
