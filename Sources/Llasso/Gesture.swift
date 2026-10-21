import AppKit
import CoreGraphics

/// Watches ordinary left-button drags anywhere on screen without changing them.
/// When a drag draws a box-shaped area (and did not move a window or drag a file),
/// it reports the box so Llasso can offer its icon there.
/// Needs Accessibility permission; without it the hotkey still works.
final class DragWatcher {
    /// Box in AppKit global coordinates, and the release point.
    var onBox: ((CGRect, CGPoint) -> Void)?
    /// Any new press, so the offered icon can go away.
    var onPress: ((CGPoint) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pressAt: CGPoint?
    private var startedAt = Date()
    private var dragged = false
    private var dragPasteboardCount = 0
    private var windowAtStart: (id: Int, bounds: CGRect)?

    static let minWidth: CGFloat = 30
    static let minHeight: CGFloat = 20
    static let minDuration: TimeInterval = 0.12

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil, AXIsProcessTrusted() else { return tap != nil }
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        // A default tap that always passes events on unchanged: it only listens, but
        // runs under Accessibility instead of needing Input Monitoring as well.
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                           options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                           callback: { _, type, event, info in
            if let info {
                Unmanaged<DragWatcher>.fromOpaque(info).takeUnretainedValue().observe(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func observe(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            let p = event.location
            pressAt = p
            startedAt = Date()
            dragged = false
            dragPasteboardCount = NSPasteboard(name: .drag).changeCount
            windowAtStart = Self.window(at: p)
            let a = Self.appKit(p)
            DispatchQueue.main.async { self.onPress?(a) }
        case .leftMouseDragged:
            dragged = true
        case .leftMouseUp:
            guard let s = pressAt, dragged else { pressAt = nil; return }
            pressAt = nil
            let p = event.location
            let quartzBox = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            guard quartzBox.width >= Self.minWidth, quartzBox.height >= Self.minHeight,
                  Date().timeIntervalSince(startedAt) >= Self.minDuration,
                  // A file, text or image was dragged somewhere.
                  NSPasteboard(name: .drag).changeCount == dragPasteboardCount,
                  !windowMovedOrResized()
            else { return }
            let box = Self.appKit(quartzBox)
            let end = Self.appKit(p)
            DispatchQueue.main.async { self.onBox?(box, end) }
        default:
            break
        }
    }

    private func windowMovedOrResized() -> Bool {
        guard let before = windowAtStart else { return false }
        guard let now = Self.windowBounds(id: before.id) else { return true }
        return now != before.bounds
    }

    /// Frontmost normal window under a Quartz point, ignoring Llasso's own windows.
    static func window(at p: CGPoint) -> (id: Int, bounds: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                  let dict = w[kCGWindowBounds as String] as CFTypeRef?,
                  let bounds = CGRect(dictionaryRepresentation: dict as! CFDictionary),
                  bounds.contains(p),
                  let id = w[kCGWindowNumber as String] as? Int else { continue }
            return (id, bounds)
        }
        return nil
    }

    static func windowBounds(id: Int) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
              let dict = list.first?[kCGWindowBounds as String] as CFTypeRef? else { return nil }
        return CGRect(dictionaryRepresentation: dict as! CFDictionary)
    }

    static func appKit(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
    }

    static func appKit(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - r.maxY, width: r.width, height: r.height)
    }
}

/// The offer after a box-shaped drag: a faint amber outline of the box and a small Llasso
/// icon by the release point. Resting the pointer on the icon (or clicking it) opens the prompt.
/// It goes away after a few seconds, or on the next click elsewhere.
@MainActor
final class Offer {
    var onAccept: ((CGRect) -> Void)?

    private var outline: NSWindow?
    private var icon: NSPanel?
    private var box: CGRect = .zero
    private var expiry: Timer?

    static let lifetime: TimeInterval = 3.5
    static let iconSize: CGFloat = 30

    func show(box: CGRect, near end: CGPoint) {
        dismiss()
        self.box = box

        let o = NSWindow(contentRect: box.insetBy(dx: -3, dy: -3), styleMask: [.borderless], backing: .buffered, defer: false)
        o.isOpaque = false
        o.backgroundColor = .clear
        o.ignoresMouseEvents = true
        o.level = .floating
        o.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        o.isReleasedWhenClosed = false
        o.contentView = DashedOutline(frame: CGRect(origin: .zero, size: o.frame.size))
        o.orderFrontRegardless()
        outline = o

        // Just below and right of the release point, kept on screen.
        let s = Self.iconSize
        var origin = CGPoint(x: end.x + 10, y: end.y - 10 - s)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(end) }) {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX + 4), v.maxX - s - 4)
            origin.y = min(max(origin.y, v.minY + 4), v.maxY - s - 4)
        }
        let p = NSPanel(contentRect: CGRect(origin: origin, size: CGSize(width: s, height: s)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        let view = OfferIcon(frame: CGRect(x: 0, y: 0, width: s, height: s))
        view.onActivate = { [weak self] in self?.accept() }
        p.contentView = view
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        icon = p

        expiry = Timer.scheduledTimer(withTimeInterval: Self.lifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    /// A press anywhere except on the icon withdraws the offer.
    func pressed(at point: CGPoint) {
        guard let icon, !icon.frame.contains(point) else { return }
        dismiss()
    }

    var isShowing: Bool { icon != nil }

    private func accept() {
        let b = box
        dismiss()
        onAccept?(b)
    }

    func dismiss() {
        expiry?.invalidate()
        expiry = nil
        outline?.orderOut(nil)
        outline = nil
        icon?.orderOut(nil)
        icon = nil
    }
}

private final class DashedOutline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
        path.lineWidth = 1.5
        path.setLineDash([5, 4], count: 2, phase: 0)
        Palette.amber.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }
}

/// Amber disc with the lasso symbol. Hover for a quarter of a second, or click, to open.
private final class OfferIcon: NSView {
    var onActivate: (() -> Void)?
    private var hoverTimer: Timer?
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        toolTip = "Ask Llasso about this box"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.onActivate?()
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        hoverTimer?.invalidate()
    }

    override func mouseDown(with event: NSEvent) {
        hoverTimer?.invalidate()
        onActivate?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        (hovering ? Palette.amber : Palette.ink).setFill()
        disc.fill()
        if !hovering {
            Palette.amber.setStroke()
            disc.lineWidth = 1.5
            disc.stroke()
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(.init(paletteColors: [hovering ? Palette.ink : Palette.amber]))
        if let img = NSImage(systemSymbolName: "lasso", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let r = CGRect(x: bounds.midX - img.size.width / 2, y: bounds.midY - img.size.height / 2,
                           width: img.size.width, height: img.size.height)
            img.draw(in: r)
        }
    }
}
