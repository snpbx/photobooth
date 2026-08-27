import Foundation
import Combine

/// Append-only file log plus an in-memory ring buffer the Admin screen renders.
final class Log: ObservableObject {
    static let shared = Log()

    @Published private(set) var entries: [LogEntry] = []

    private let queue = DispatchQueue(label: "photobooth.log")
    private let dir: URL
    private var handle: FileHandle?
    private var openedDay: String = ""
    private let maxEntries = 800

    private init() {
        dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Photobooth", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var logDirectory: URL { dir }

    func info(_ m: String)  { write(.info, m) }
    func warn(_ m: String)  { write(.warn, m) }
    func error(_ m: String) { write(.error, m) }

    private func write(_ level: LogEntry.Level, _ message: String) {
        let entry = LogEntry(at: Date(), level: level, message: message)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
        queue.async { self.appendToFile(entry) }
    }

    private func appendToFile(_ e: LogEntry) {
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        let day = dayFmt.string(from: e.at)

        if day != openedDay || handle == nil {
            handle?.closeFile()
            let url = dir.appendingPathComponent("photobooth-\(day).log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
            openedDay = day
        }

        let stampFmt = DateFormatter()
        stampFmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "\(stampFmt.string(from: e.at))  \(e.level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0))  \(e.message)\n"
        if let d = line.data(using: .utf8) { handle?.write(d) }
    }

    func todayLogURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return dir.appendingPathComponent("photobooth-\(f.string(from: Date())).log")
    }
}
