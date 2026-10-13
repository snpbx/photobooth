import SwiftUI
import AppKit

/// The console as it is used from a phone, over screen sharing, standing next to
/// the booth.
///
/// Everything else in Admin assumes a mouse and a window: three columns of cards,
/// hairlines, eleven-point captions. None of that survives being driven with a
/// thumb on a six-inch screen from across a room. This is the four things an
/// operator actually touches during an event — how many copies, print it again,
/// which layout, and take that one again — at a size that can be hit while
/// holding a drink.
///
/// Deliberately not a responsive version of the Control tab. A layout that
/// collapses gracefully still shows everything, and everything is the problem:
/// the whole point is that there is nothing here to tap by mistake.
struct QuickTab: View {
    @ObservedObject var c: BoothController

    private let tap: CGFloat = 56

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                status
                copies
                layouts
                actions
                retakes
            }
            .padding(18)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .onAppear { c.adoptOwnLayoutIfNeeded() }
    }

    // MARK: Where things stand

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(tint: c.cameraState.isReady ? Palette.statusOK : Palette.statusBad,
                          pulsing: !c.cameraState.isReady)
                Text(c.state.name)
                    .font(.system(size: 20, weight: .bold))
                Spacer(minLength: 8)
                if let p = c.progress {
                    Text("\(p.shot)/\(p.total)")
                        .font(.system(size: 20, weight: .bold))
                        .monospacedDigit()
                }
            }
            Text(c.activeEvent?.name ?? "No event")
                .font(.system(size: 14))
                .foregroundStyle(Palette.textDim)
                .lineLimit(1)
        }
    }

    // MARK: Copies

    private var copies: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Copies", detail: "\(c.settings.copies) per session")
            FlowRow(spacing: 8, perRow: 5) {
                (1...10).map { n in
                    AnyView(
                        Button { c.settingsService.settings.copies = n } label: {
                            Text("\(n)")
                                .font(.system(size: 19, weight: .semibold))
                                .monospacedDigit()
                                .frame(width: tap, height: tap)
                                .background(c.settings.copies == n ? Palette.ink : Palette.surfaceAlt,
                                            in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(c.settings.copies == n ? Palette.paper : Palette.text)
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    )
                }
            }
        }
    }

    // MARK: Layouts — names only

    /// Names, not thumbnails. A sketch of eight grey rectangles tells nobody
    /// which layout is which at arm's length, and it halves how many fit on the
    /// screen; the operator named these themselves.
    private var layouts: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Layout", detail: c.activeTemplate?.name ?? c.settings.layout.title)
            ForEach(c.dryRunLayouts) { choice in
                let selected = isSelected(choice)
                Button {
                    switch choice {
                    case .builtIn(let l):      c.useBuiltInLayout(l)
                    case .template(let id, _): c.useTemplate(id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(selected ? Palette.ink : Palette.hairline)
                        Text(choice.name)
                            .font(.system(size: 17, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: tap)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? Palette.ink.opacity(0.10) : Palette.surfaceAlt,
                                in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(c.state.isSessionActive)
            }
        }
    }

    private func isSelected(_ choice: DryRunLayout) -> Bool {
        switch choice {
        case .builtIn(let l):      return c.activeTemplate == nil && c.settings.layout == l
        case .template(let id, _): return c.activeTemplate?.id == id
        }
    }

    // MARK: Print again

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Print", detail: c.currentSession.map { "Last: \($0.id)" } ?? "Nothing yet")
            Button {
                c.printCurrentSession()
            } label: {
                Label("Reprint the last session", systemImage: "printer")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: tap)
            }
            .buttonStyle(.plain)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(Palette.paper)
            .disabled(c.currentSession?.printFileName == nil || c.isPrintBusy)
            .opacity(c.currentSession?.printFileName == nil || c.isPrintBusy ? 0.45 : 1)
        }
    }

    // MARK: Retakes

    private var retakes: some View {
        let total = max(1, c.shotCount)
        let taken = Set((c.currentSession?.photos ?? []).map(\.index))
        return VStack(alignment: .leading, spacing: 8) {
            heading("Retake", detail: c.retakeQueue.isEmpty
                    ? "Tap a number to shoot it again"
                    : "\(c.retakeQueue.count) queued")
            FlowRow(spacing: 8, perRow: 5) {
                (1...total).map { n in
                    let queued = c.retakeQueue.contains(n)
                    let can = c.state.isSessionActive
                        ? (taken.contains(n) || c.progress?.shot == n)
                        : (c.canRetake && taken.contains(n))
                    return AnyView(
                        Button { c.toggleRetake(shot: n) } label: {
                            Text("\(n)")
                                .font(.system(size: 19, weight: .semibold))
                                .monospacedDigit()
                                .frame(width: tap, height: tap)
                                .background(queued ? Palette.ember : Palette.surfaceAlt,
                                            in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(queued ? Palette.paper
                                                        : (can ? Palette.text : Palette.textDim.opacity(0.5)))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(!can)
                    )
                }
            }
            if !c.retakeQueue.isEmpty, !c.state.isSessionActive {
                Button { c.resumeForRetakes() } label: {
                    Label("Shoot the retakes", systemImage: "camera")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: tap)
                }
                .buttonStyle(.plain)
                .background(Palette.ember, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(Palette.paper)
            }
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .bold))
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textDim)
                .lineLimit(1)
        }
    }
}
