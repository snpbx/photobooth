import AppKit
import SwiftUI
import Combine
import CoreGraphics

/// Watches for the physical booth button.
///
/// A photobooth button is almost always a USB HID device that presents itself to
/// macOS as a keyboard and sends one keystroke when pressed — arcade buttons,
/// foot switches and the little "start" domes all work this way. So this listens
/// for a key rather than talking to the USB device directly, which is what makes
/// it work with any button the operator happens to buy.
///
/// Two monitors are installed:
///
///   * a **local** monitor, which sees the key whenever Photobooth is frontmost;
///   * a **global** monitor, which sees it even when the guest has clicked away,
///     the Finder is in front, or the mouse pointer is on the other display.
///
/// The global one is the whole point — an unattended booth cannot be relied on to
/// keep keyboard focus — but macOS gates it behind Input Monitoring, which the
/// operator has to grant once in System Settings. Until they do, the button only
/// works while a Photobooth window is frontmost, and Admin says so plainly.
@MainActor
final class TriggerService: ObservableObject {

    enum Access: Equatable {
        case notNeeded          // global listening switched off
        case granted
        case denied

        var label: String {
            switch self {
            case .notNeeded: return "Window focus only"
            case .granted:   return "Works anywhere"
            case .denied:    return "Needs Input Monitoring"
            }
        }

        var tint: Color {
            switch self {
            case .granted:   return VHS.ok
            case .denied:    return VHS.amber
            case .notNeeded: return VHS.dim
            }
        }
    }

    /// Fired when the button is pressed. Set by BoothController.
    var onPress: (() -> Void)?

    @Published private(set) var access: Access = .notNeeded
    @Published private(set) var lastPressAt: Date?
    @Published private(set) var pressCount = 0
    /// While true the next keystroke is captured as the new trigger key rather
    /// than starting a session — "press your button now" in Admin.
    @Published private(set) var isLearning = false
    @Published private(set) var learnedLabel: String?

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var enabled = true
    private var keyCode: UInt16 = 76           // keypad enter, what most booth buttons send
    private var wantsGlobal = true
    private var debounce: TimeInterval = 0.6
    private var lastAccepted = Date.distantPast
    private var learnHandler: ((UInt16, String) -> Void)?

    init() {
        installLocal()
    }

    deinit {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Configuration

    func configure(_ s: AppSettings) {
        enabled = s.triggerEnabled
        keyCode = UInt16(clamping: s.triggerKeyCode)
        debounce = max(0.05, Double(s.triggerDebounceMs) / 1000)
        let newGlobal = s.triggerEnabled && s.triggerGlobal
        if newGlobal != wantsGlobal || (newGlobal && globalMonitor == nil) {
            wantsGlobal = newGlobal
            refreshGlobalMonitor()
        } else {
            refreshAccess()
        }
    }

    var keyLabel: String { Self.label(for: keyCode) }

    // MARK: - Input Monitoring permission

    /// Preflight only — never prompts. Called on every settings change so the
    /// console reflects a permission the operator granted in System Settings
    /// while the app was running.
    func refreshAccess() {
        guard wantsGlobal else { access = .notNeeded; return }
        access = CGPreflightListenEventAccess() ? .granted : .denied
    }

    /// Asks macOS for Input Monitoring. Shows the system prompt the first time and
    /// is a no-op afterwards, which is why Admin also offers the Settings link.
    func requestAccess() {
        guard !CGPreflightListenEventAccess() else {
            access = .granted
            refreshGlobalMonitor()
            return
        }
        _ = CGRequestListenEventAccess()
        Log.shared.info("Requested Input Monitoring for the booth button")
        // The grant lands after the operator answers, so re-check shortly.
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if CGPreflightListenEventAccess() {
                    self.access = .granted
                    self.refreshGlobalMonitor()
                    Log.shared.info("Input Monitoring granted — booth button now works anywhere")
                    return
                }
            }
        }
    }

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Learning a button

    /// Captures the next keystroke as the trigger key. Times out on its own so a
    /// forgotten Learn mode cannot swallow the operator's keyboard.
    func learn(_ completion: @escaping (UInt16, String) -> Void) {
        isLearning = true
        learnedLabel = nil
        learnHandler = completion
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if self.isLearning { self.cancelLearning() }
        }
    }

    func cancelLearning() {
        isLearning = false
        learnHandler = nil
    }

    // MARK: - Monitors

    private func installLocal() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let mods = event.modifierFlags
            guard let self else { return event }
            let swallow = MainActor.assumeIsolated { self.handleLocal(keyCode: code, modifiers: mods) }
            return swallow ? nil : event
        }
    }

    private func refreshGlobalMonitor() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        guard wantsGlobal else { access = .notNeeded; return }
        guard CGPreflightListenEventAccess() else {
            access = .denied
            return
        }
        access = .granted
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            guard let self else { return }
            MainActor.assumeIsolated { self.handleGlobal(keyCode: code) }
        }
    }

    // MARK: - Dispatch

    private func handleLocal(keyCode code: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        if isLearning {
            finishLearning(code)
            return true
        }
        guard enabled, code == keyCode else { return false }
        // A modifier means somebody meant a shortcut, not the booth button.
        guard !modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option) else {
            return false
        }
        // Never steal a keystroke the operator is typing into a field.
        if isEditingText { return false }
        fire(source: "local")
        return true
    }

    private func handleGlobal(keyCode code: UInt16) {
        // Global learning is deliberately not supported: the operator is looking
        // at Admin when they press Learn, so the local monitor has it.
        guard enabled, !isLearning, code == keyCode else { return }
        fire(source: "global")
    }

    /// Buttons bounce and guests mash — one press must not start two sessions.
    private func fire(source: String) {
        let now = Date()
        guard now.timeIntervalSince(lastAccepted) >= debounce else { return }
        lastAccepted = now
        lastPressAt = now
        pressCount += 1
        Log.shared.info("Booth button pressed (\(source), key \(keyLabel))")
        onPress?()
    }

    private func finishLearning(_ code: UInt16) {
        let label = Self.label(for: code)
        isLearning = false
        learnedLabel = label
        keyCode = code
        learnHandler?(code, label)
        learnHandler = nil
        Log.shared.info("Booth button learned: \(label)")
    }

    private var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        if let field = responder as? NSTextField, field.isEditable { return true }
        return false
    }

    // MARK: - Key names

    /// Only the keys a booth button plausibly sends are named; anything else is
    /// shown by its code, which is still enough to identify it in Admin.
    static func label(for code: UInt16) -> String {
        switch code {
        case 36:  return "Return"
        case 76:  return "Keypad Enter"
        case 49:  return "Space"
        case 48:  return "Tab"
        case 53:  return "Esc"
        case 51:  return "Delete"
        case 123: return "Left Arrow"
        case 124: return "Right Arrow"
        case 125: return "Down Arrow"
        case 126: return "Up Arrow"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64:  return "F17"
        case 79:  return "F18"
        case 80:  return "F19"
        case 82:  return "Keypad 0"
        case 83:  return "Keypad 1"
        case 84:  return "Keypad 2"
        case 85:  return "Keypad 3"
        case 86:  return "Keypad 4"
        case 87:  return "Keypad 5"
        case 88:  return "Keypad 6"
        case 89:  return "Keypad 7"
        case 91:  return "Keypad 8"
        case 92:  return "Keypad 9"
        default:
            if let ch = Self.character(for: code) { return ch.uppercased() }
            return "Key \(code)"
        }
    }

    private static func character(for code: UInt16) -> String? {
        let letters: [UInt16: String] = [
            0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h",
            34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o",
            35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v",
            13: "w", 7: "x", 16: "y", 6: "z",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
            22: "6", 26: "7", 28: "8", 25: "9", 29: "0"
        ]
        return letters[code]
    }
}