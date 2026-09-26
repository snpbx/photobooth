import Foundation
import Combine

/// Settings persisted as JSON in Application Support so the operator can inspect
/// or hand-edit them between events.
@MainActor
final class SettingsService: ObservableObject {
    @Published var settings: AppSettings {
        didSet { scheduleSave() }
    }

    private let url: URL
    private var saveWork: DispatchWorkItem?

    /// Where settings and any uploaded branding live.
    ///
    /// PHOTOBOOTH_SUPPORT_DIR lets the screenshot harness run against a scratch
    /// config instead of overwriting the operator's live settings.
    nonisolated static var supportDirectory: URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["PHOTOBOOTH_SUPPORT_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Photobooth", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    init() {
        url = Self.supportDirectory.appendingPathComponent("settings.json")
        settings = Self.load(from: url)
    }

    /// Synthesised Codable decoding treats a missing key as an error, so a
    /// settings file written by an earlier version would fail wholesale and reset
    /// every preference. Saved values are merged over the defaults instead, which
    /// keeps the operator's timings and branding across upgrades.
    private static func load(from url: URL) -> AppSettings {
        let fallback = AppSettings()
        guard let saved = try? Data(contentsOf: url) else { return fallback }

        guard let defaultsData = try? JSONEncoder().encode(fallback),
              var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any],
              let savedObject = try? JSONSerialization.jsonObject(with: saved) as? [String: Any]
        else {
            return (try? JSONDecoder().decode(AppSettings.self, from: saved)) ?? fallback
        }

        for (key, value) in savedObject where merged[key] != nil {
            merged[key] = value
        }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: mergedData)
        else {
            // A value the current version cannot parse — keep the rest, log it once.
            Log.shared.warn("Some saved settings could not be read; defaults used for those.")
            return fallback
        }
        return migrated(decoded)
    }

    /// Carries settings whose *meaning* changed, which merging cannot see.
    ///
    /// `gifSeconds` used to be the run-up replayed from live view, 1–6 seconds;
    /// it is now how long one photograph is held, 0.3–3. A file saved with the
    /// old meaning asks for a four-second hold per photograph — a minute-long
    /// loop for an eight-shot session — and would show as a blank in a picker
    /// whose options it no longer matches.
    private static func migrated(_ s: AppSettings) -> AppSettings {
        var out = s
        if out.gifSeconds > GIFRenderer.maxSeconds {
            out.gifSeconds = AppSettings().gifSeconds
            Log.shared.info("GIF timing carried over to the new one-frame-per-photograph loop")
        }
        return out
    }

    var settingsFileURL: URL { url }

    /// Debounced so dragging a stepper does not hammer the disk.
    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = settings
        let target = url
        let work = DispatchWorkItem {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(snapshot) {
                try? data.write(to: target, options: .atomic)
            }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(settings) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func resetToDefaults() {
        settings = AppSettings()
        saveNow()
        Log.shared.warn("Settings reset to defaults")
    }
}
