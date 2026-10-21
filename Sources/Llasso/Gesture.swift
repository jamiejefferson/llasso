import AppKit
import CoreGraphics

/// Starts Llasso from a right-button drag anywhere on screen.
///
/// A session-wide event tap holds back every right-button press. If the pointer moves
/// more than a few points before release, the press becomes a Llasso box. If it doesn't,
/// the click is replayed so the app's context menu still opens, on release instead of press.
/// Needs Accessibility permission; without it the hotkey still works.
final class GestureTap {
    var onBegan: ((CGPoint) -> Void)?
    var onMoved: ((CGPoint) -> Void)?
    var onEnded: ((CGPoint) -> Void)?
    /// Asked on every press: return false to let the click through untouched.
    var shouldIntercept: (() -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var down: CGPoint?
    private var dragging = false
    /// Marks the clicks Llasso replays so the tap lets them through.
    private static let replayMarker: Int64 = 0x4C4C53

    static let threshold: CGFloat = 6

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil, AXIsProcessTrusted() else { return tap != nil }
        let mask = (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                           callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<GestureTap>.fromOpaque(info).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }, userInfo: me) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            break
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker {
            return Unmanaged.passUnretained(event)
        }
        let p = event.location   // Quartz global: origin top-left of the main display

        switch type {
        case .rightMouseDown:
            guard shouldIntercept?() ?? true else { return Unmanaged.passUnretained(event) }
            down = p
            dragging = false
            return nil
        case .rightMouseDragged:
            guard let start = down else { return Unmanaged.passUnretained(event) }
            if !dragging, hypot(p.x - start.x, p.y - start.y) > Self.threshold {
                dragging = true
                let a = appKit(start)
                DispatchQueue.main.async { self.onBegan?(a) }
            }
            if dragging {
                let a = appKit(p)
                DispatchQueue.main.async { self.onMoved?(a) }
            }
            return nil
        case .rightMouseUp:
            guard let start = down else { return Unmanaged.passUnretained(event) }
            down = nil
            if dragging {
                dragging = false
                let a = appKit(p)
                DispatchQueue.main.async { self.onEnded?(a) }
            } else {
                replayClick(at: start, clickCount: event.getIntegerValueField(.mouseEventClickState))
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Post the held-back right click again, marked so the tap ignores it.
    private func replayClick(at p: CGPoint, clickCount: Int64) {
        let src = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p,
                                  mouseButton: .right) else { continue }
            e.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
            e.setIntegerValueField(.mouseEventClickState, value: max(1, clickCount))
            e.post(tap: .cgSessionEventTap)
        }
    }

    private func appKit(_ p: CGPoint) -> CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: mainHeight - p.y)
    }
}
