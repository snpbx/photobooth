import Foundation

/// A rehearsal of a whole evening, run from the console.
///
/// What it is for: the things that only break on the night. The USB link to the
/// camera under repeated capture, every layout actually composing, the upload
/// queue draining, the pages appearing, the codes resolving. All of it with real
/// photographs from the real camera and real uploads to the real site — and
/// **no paper**, because a rehearsal that empties a pack of fifty-four is a
/// rehearsal nobody runs twice.
struct DryRunPlan {
    /// How many guests to pretend to photograph.
    var customers: Int = 3
    /// Take the next layout for each guest, so a run of five covers five
    /// arrangements rather than testing one of them five times.
    var cycleLayouts: Bool = true
    /// Publish for real. Off is for rehearsing in a cellar with no signal.
    var uploads: Bool = true
    /// Seconds between one guest leaving and the next arriving.
    var gap: Double = 2
}

/// What the console shows while a rehearsal is running.
struct DryRunProgress: Equatable {
    var customer: Int
    var total: Int
    /// The layout this guest is being photographed against.
    var layout: String
    var note: String
    /// Set when the run stops early, so the card can say why rather than
    /// simply emptying itself.
    var failure: String?

    var isFinished: Bool { customer > total || failure != nil }
}

/// One entry in the rehearsal's layout rota: a built-in arrangement, or one of
/// the operator's own.
enum DryRunLayout: Identifiable, Equatable {
    case builtIn(PrintLayout)
    case template(id: String, name: String)

    var id: String {
        switch self {
        case .builtIn(let l):      return "built-\(l.rawValue)"
        case .template(let id, _): return "tpl-\(id)"
        }
    }

    var name: String {
        switch self {
        case .builtIn(let l):     return l.title
        case .template(_, let n): return n
        }
    }
}
