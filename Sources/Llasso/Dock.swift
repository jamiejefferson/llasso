import AppKit
import SwiftUI

/// The Working chips: one small glass chip per request that is running, or waiting on the user,
/// with its card out of sight. They stack at the right edge of the screen, out of the way of
/// whatever the user does next. A click on a chip brings its card up beside it.
@MainActor
final class WorkingDock: ObservableObject {
    static let shared = WorkingDock()
    @Published private(set) var jobs: [Job] = []
    private var panel: FloatingPanel?

    static let width: CGFloat = 150
    static let rowHeight: CGFloat = 40
    /// Gap between the chips and the screen's right edge.
    static let inset: CGFloat = 12

    func refresh() {
        let waiting = Controller.shared.jobs.reversed().filter { j in
            !j.closed && !j.isVisible && (j.isRunning || j.needsYou)
        } as [Job]
        if waiting.map(ObjectIdentifier.init) != jobs.map(ObjectIdentifier.init) { jobs = waiting }
        if jobs.isEmpty { panel?.orderOut(nil); return }
        let panel = self.panel ?? make()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let height = CGFloat(jobs.count) * Self.rowHeight + 2 * Glass.margin
        let v = screen.visibleFrame
        let frame = CGRect(x: v.maxX - Self.inset - Self.width - Glass.margin,
                           y: v.midY + 80 + Glass.margin - height,
                           width: Self.width + 2 * Glass.margin, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
    }

    /// Put a card at the right edge, its top level with the chips, stepped down a little for
    /// each card already showing so two never sit exactly on top of each other.
    func placeCard(_ card: FloatingPanel, on screen: NSScreen) {
        let v = screen.visibleFrame
        let showing = Controller.shared.jobs.filter(\.isVisible).count
        let top = min(v.maxY - 8, v.midY + 80 + Glass.margin + CGFloat(showing) * 28)
        card.setFrameOrigin(CGPoint(x: v.maxX - card.frame.width + Glass.margin - Self.inset,
                                    y: top - card.frame.height))
    }

    /// Centre of the first chip, for the test.
    var firstChipCentre: CGPoint? {
        guard let panel, panel.isVisible, !jobs.isEmpty else { return nil }
        return CGPoint(x: panel.frame.midX, y: panel.frame.maxY - Glass.margin - Self.rowHeight / 2)
    }

    private func make() -> FloatingPanel {
        let p = FloatingPanel(size: CGSize(width: Self.width, height: Self.rowHeight))
        p.isMovableByWindowBackground = false
        p.contentView = NSHostingView(rootView: DockView(dock: self))
        panel = p
        return p
    }
}

struct DockView: View {
    @ObservedObject var dock: WorkingDock

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(dock.jobs, id: \.id) { job in
                DockChip(job: job, card: job.card).onTapGesture { job.show() }
            }
        }
        .frame(width: WorkingDock.width, alignment: .trailing)
        .padding(Glass.margin)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// "Working" with a turning arc, or "Needs you" with a gold dot when the job is waiting.
struct DockChip: View {
    let job: Job
    @ObservedObject var card: CardModel

    var body: some View {
        HStack(spacing: 8) {
            if job.needsYou {
                Circle().fill(Color.llDot).frame(width: 8, height: 8)
            } else {
                StatusMark(status: 0)
            }
            Text(job.needsYou ? "Needs you" : "Working")
                .font(.system(size: 12.5, weight: .medium)).foregroundColor(.llText)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .chipGlass()
        .contentShape(Capsule())
        .help(job.title)
    }
}
