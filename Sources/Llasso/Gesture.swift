import AppKit
import CoreGraphics

/// Hold ⌘ and drag to draw a box. The drag goes to Llasso and never reaches the app under it.
/// A ⌘-click that doesn't move is handed back to the app unchanged, so ⌘-click still opens
/// links in new tabs and adds to selections. Presses in the menu bar are left alone, where
/// ⌘-drag rearranges the icons.
/// Needs Accessibility permission; without it the menu and ⌃⌥S still work.
final class CommandDrag {
    /// Points in AppKit global coordinates. `onStart` returns false when Llasso can't take a box now.
    var onStart: ((CGPoint) -> Bool)?
    var onMove: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?

    private enum Tracking { case none, pending(start: CGPoint, down: CGEvent), drawing }
    private var tracking = Tracking.none
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// How far the pointer moves before a ⌘-press counts as a drag rather than a click.
    static let dragDistance: CGFloat = 4
    /// Marks the clicks Llasso hands back, so the tap lets them through.
    private static let replayed: Int64 = 0x4C4C5353

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil, AXIsProcessTrusted() else { return tap != nil }
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                           callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let watcher = Unmanaged<CommandDrag>.fromOpaque(info).takeUnretainedValue()
            return watcher.handle(type: type, event: event) ? Unmanaged.passUnretained(event) : nil
        }, userInfo: me) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// Returns true to pass the event on, false to keep it from the app.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .leftMouseDown:
            guard event.getIntegerValueField(.eventSourceUserData) != Self.replayed,
                  event.flags.contains(.maskCommand),
                  !Self.inMenuBar(event.location),
                  let down = event.copy() else { return true }
            tracking = .pending(start: event.location, down: down)
            return false
        case .leftMouseDragged:
            switch tracking {
            case .none:
                return true
            case .pending(let start, _):
                let p = event.location
                guard hypot(p.x - start.x, p.y - start.y) >= Self.dragDistance else { return false }
                if onStart?(Self.appKit(start)) == true {
                    tracking = .drawing
                    onMove?(Self.appKit(p))
                } else {
                    // Llasso is busy with a prompt: let the app have the drag after all.
                    replay()
                }
                return false
            case .drawing:
                onMove?(Self.appKit(event.location))
                return false
            }
        case .leftMouseUp:
            switch tracking {
            case .none:
                return true
            case .pending:
                replay(up: event)
                return false
            case .drawing:
                tracking = .none
                onEnd?()
                return false
            }
        default:
            return true
        }
    }

    /// Hand a ⌘-press back to the app: the held press, then the release if there is one.
    private func replay(up: CGEvent? = nil) {
        guard case .pending(_, let down) = tracking else { return }
        tracking = .none
        for e in [down, up?.copy()].compactMap({ $0 }) {
            e.setIntegerValueField(.eventSourceUserData, value: Self.replayed)
            e.post(tap: .cgSessionEventTap)
        }
    }

    /// The menu bar of whichever screen holds the Quartz point.
    private static func inMenuBar(_ p: CGPoint) -> Bool {
        let a = appKit(p)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(a) }) else { return false }
        return a.y > screen.visibleFrame.maxY
    }

    static func appKit(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
    }
}
