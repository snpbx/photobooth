import Foundation

/// Carries the operator's layouts between their Macs.
///
/// The booth's settings folder is itself a git repository — settings, the
/// layouts and the branding artwork — so "sync" here means: fetch what the
/// other machine pushed, reconcile it with what is here, and push the result
/// back.
///
/// **Reconciled by hand rather than by git.** Both machines keep their layouts
/// in one `templates.json`, so a design made on each would be two edits to the
/// same line of the same file: a merge conflict, in a folder nobody is going to
/// open a terminal in at an event. Instead the two lists are merged by layout:
/// each one is matched by id and the newer of the two kept, which is a question
/// a layout can actually answer — it carries the moment it was last saved. The
/// file is then written whole, so git only ever sees one side of a change and
/// has nothing to conflict about.
///
/// What that costs: a layout deleted on one Mac comes back if the other still
/// has it, because "deleted here" and "not made here yet" look identical in a
/// list. Removing it on both is the way to be rid of it, and that is the right
/// trade for a booth — a layout that reappears is a nuisance, a layout that
/// vanishes the night before an event is not.
@MainActor
final class LayoutSync: ObservableObject {

    enum Status: Equatable {
        case idle
        case working
        case done(Date, String)
        case failed(String)

        var isWorking: Bool { self == .working }
    }

    @Published private(set) var status: Status = .idle

    private let log = Log.shared
    nonisolated private static let gitPath = "/usr/bin/git"
    nonisolated private static let branch = "main"

    /// The settings folder, which is the repository.
    private nonisolated var repo: URL { SettingsService.supportDirectory }

    /// Whether syncing is even possible here: a repository with somewhere to
    /// push to. A booth that has never been set up for it says so plainly
    /// rather than offering a button that cannot work.
    nonisolated var isConfigured: Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path)
            && (try? git(["remote", "get-url", "origin"])) != nil
    }

    // MARK: - The one action

    func sync(_ store: TemplateStore, branding: Bool = true) async {
        guard !status.isWorking else { return }
        guard isConfigured else {
            status = .failed("This Mac has no layout repository yet — see the README.")
            return
        }
        status = .working

        do {
            let summary = try await Task.detached(priority: .userInitiated) { [self] in
                try await reconcile(store, branding: branding)
            }.value
            status = .done(Date(), summary)
            log.info("Layouts synced — \(summary)")
        } catch {
            let message = (error as? SyncError)?.text ?? error.localizedDescription
            status = .failed(message)
            log.error("Layout sync failed: \(message)")
        }
    }

    enum SyncError: Error {
        case git(String, String)
        case noGit
        case unreadableLibrary

        var text: String {
            switch self {
            case .noGit: return "git is not installed — run xcode-select --install."
            case .unreadableLibrary:
                return "This Mac's own layouts could not be read, so nothing was changed."
            case .git(let step, let detail):
                // Credentials are the usual cause and the least obvious one.
                if detail.contains("Authentication") || detail.contains("could not read Username") {
                    return "GitHub refused the \(step) — run gh auth login in a terminal."
                }
                return "git \(step): \(detail)"
            }
        }
    }

    // MARK: - Off the main actor

    private nonisolated func reconcile(_ store: TemplateStore, branding: Bool) async throws -> String {
        try git(["fetch", "--quiet", "origin", Self.branch])

        let mine = await store.templates
        // A library that failed to load reads as an empty one, and an empty one
        // takes everything the other Mac has — which would quietly replace the
        // layouts on this Mac with somebody else's. If there is a file here with
        // something in it, it has to have been understood first.
        let localFile = repo.appendingPathComponent("templates.json")
        if mine.isEmpty,
           let size = (try? FileManager.default
            .attributesOfItem(atPath: localFile.path))?[.size] as? Int, size > 2 {
            throw SyncError.unreadableLibrary
        }
        let theirs = remoteTemplates()
        let (merged, taken, sent) = Self.merge(mine: mine, theirs: theirs)

        if taken > 0 {
            await store.replaceAll(merged)
        }
        if branding { try takeNewArtwork() }

        // Commit whatever this Mac now holds — the merged layouts, any artwork
        // it has that the other one does not, and whatever else in the folder
        // has moved since the last sync.
        try git(["add", "-A"])
        let dirty = (try? git(["status", "--porcelain"]))?.isEmpty == false
        if dirty {
            try git(["-c", "user.name=Photobooth",
                     "-c", "user.email=booth@localhost",
                     "commit", "--quiet", "-m", "Layouts from \(Self.machine())"])
        }
        if dirty || sent > 0 {
            do {
                try git(["push", "--quiet", "origin", "HEAD:\(Self.branch)"])
            } catch {
                // Somebody pushed between our fetch and our push. Deliberately
                // not a rebase: replaying our commit over theirs would ask git
                // to merge the file we merged by hand, which is the conflict
                // this whole design exists to avoid. Moving onto their commit
                // with our work still in the tree cannot conflict — then the
                // layouts are merged once more, against what they just pushed.
                try git(["fetch", "--quiet", "origin", Self.branch])
                try git(["reset", "--soft", "origin/\(Self.branch)"])
                let again = Self.merge(mine: await store.templates, theirs: remoteTemplates()).0
                await store.replaceAll(again)
                try git(["add", "-A"])
                if (try? git(["status", "--porcelain"]))?.isEmpty == false {
                    try git(["-c", "user.name=Photobooth",
                             "-c", "user.email=booth@localhost",
                             "commit", "--quiet", "-m", "Layouts from \(Self.machine())"])
                }
                try git(["push", "--quiet", "origin", "HEAD:\(Self.branch)"])
            }
        }

        switch (taken, dirty) {
        case (0, false): return "already the same on both Macs"
        case (0, true):  return "sent this Mac's layouts"
        case (_, false): return "took \(taken) layout(s) from the other Mac"
        default:         return "took \(taken), sent this Mac's own"
        }
    }

    /// The layouts as the other machine last pushed them. An empty list when
    /// the file is not there yet, which is simply a repository nobody has
    /// synced layouts into.
    private nonisolated func remoteTemplates() -> [PrintTemplate] {
        guard let json = try? git(["show", "origin/\(Self.branch):templates.json"]),
              let data = json.data(using: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([PrintTemplate].self, from: data)) ?? []
    }

    /// Union by id, newest save wins.
    ///
    /// - Returns: the merged list, how many came from the other Mac, and how
    ///   many of ours it has never seen.
    nonisolated static func merge(mine: [PrintTemplate],
                                  theirs: [PrintTemplate]) -> ([PrintTemplate], Int, Int) {
        var byID: [String: PrintTemplate] = [:]
        var order: [String] = []
        for t in mine {
            byID[t.id] = t
            order.append(t.id)
        }

        var taken = 0
        for t in theirs {
            if let ours = byID[t.id] {
                // A second's grace: two machines that saved the same layout in
                // the same moment should not flip back and forth for ever.
                if t.updatedAt > ours.updatedAt.addingTimeInterval(1) {
                    byID[t.id] = t
                    taken += 1
                }
            } else {
                byID[t.id] = t
                order.append(t.id)
                taken += 1
            }
        }
        let theirIDs = Set(theirs.map(\.id))
        let sent = mine.filter { !theirIDs.contains($0.id) }.count
        return (order.compactMap { byID[$0] }, taken, sent)
    }

    /// Artwork the other Mac has and this one does not.
    ///
    /// Add-only on purpose: a logo is referenced by file name from inside a
    /// layout, so a sync that removed one would leave a layout pointing at
    /// nothing — and the whole reason the other machine sent it is that one of
    /// its layouts needs it.
    private nonisolated func takeNewArtwork() throws {
        let listing = (try? git(["ls-tree", "-r", "--name-only",
                                 "origin/\(Self.branch)", "--", "Branding"])) ?? ""
        let wanted = listing.split(separator: "\n").map(String.init)
        guard !wanted.isEmpty else { return }
        let missing = wanted.filter {
            !FileManager.default.fileExists(atPath: repo.appendingPathComponent($0).path)
        }
        guard !missing.isEmpty else { return }
        try git(["checkout", "origin/\(Self.branch)", "--"] + missing)
    }

    // MARK: - git

    @discardableResult
    private nonisolated func git(_ args: [String], timeout: TimeInterval = 90) throws -> String {
        guard FileManager.default.fileExists(atPath: Self.gitPath) else { throw SyncError.noGit }
        var env = ProcessInfo.processInfo.environment
        // Never stop for a password prompt: a dialog nobody can see would hang
        // the sync for ever, where a refusal can be reported and acted on.
        env["GIT_TERMINAL_PROMPT"] = "0"
        let r = Shell.run(Self.gitPath, ["-C", repo.path] + args, timeout: timeout, environment: env)
        guard r.status == 0 else {
            let detail = (r.err.isEmpty ? r.out : r.err)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SyncError.git(args.first ?? "?", detail.isEmpty ? "exit \(r.status)" : detail)
        }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func machine() -> String {
        Host.current().localizedName ?? "a Mac"
    }
}
