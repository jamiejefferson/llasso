import AppKit
import CoreGraphics
import LlassoKit

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

/// The offer after a box-shaped drag: the gold thread round the box at rest, and the Llasso
/// mark on a small glass disc by the release point. Resting the pointer on the icon opens the
/// prompt; pressing and holding it records speech until release, then sends. Once opened, the
/// icon stays on the prompt's mic as the hold-to-talk button. Left alone for three seconds,
/// the thread and the icon fray away; a hover before they are gone pulls them back.
@MainActor
final class Offer {
    /// Hover: open the prompt for the box.
    var onOpen: ((CGRect) -> Void)?
    /// Press on the icon: open the prompt if needed and start recording.
    var onHoldBegan: ((CGRect) -> Void)?
    /// Release after a press: send what was said.
    var onHoldEnded: (() -> Void)?

    private var outline: NSWindow?
    private var lasso: LassoView?
    private var icon: NSPanel?
    private var iconView: OfferIcon?
    private var box: CGRect = .zero
    private var opened = false
    private var expiry: Timer?
    private var fraying: Timer?

    /// Quiet time before the thread starts to fray, and how long the fray takes.
    static let restTime: TimeInterval = 3
    static let frayTime: TimeInterval = 1.2
    /// The icon's window: room round the 34pt disc for the hover swell, the halo and the talk rings.
    static let iconWindow: CGFloat = 100

    func show(box: CGRect, near end: CGPoint) {
        dismiss()
        self.box = box
        opened = false

        let (o, view) = LassoWindow.make(round: box)
        view.apply(.resting, animated: false)
        o.orderFrontRegardless()
        view.drawOn()
        outline = o
        lasso = view

        // Just below and right of the release point, kept on screen.
        let s = Self.iconWindow
        let centre = CGPoint(x: end.x + 27, y: end.y - 27)
        var origin = CGPoint(x: centre.x - s / 2, y: centre.y - s / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(end) }) {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX - 10), v.maxX - s + 10)
            origin.y = min(max(origin.y, v.minY - 10), v.maxY - s + 10)
        }
        let p = NSPanel(contentRect: CGRect(origin: origin, size: CGSize(width: s, height: s)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Above the overlay and the prompt, so it stays usable as the talk button.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        let iconView = OfferIcon(frame: CGRect(x: 0, y: 0, width: s, height: s))
        iconView.onHover = { [weak self] in self?.open() }
        iconView.onEnter = { [weak self] in self?.pointerEntered() }
        iconView.onExit = { [weak self] in self?.pointerLeft() }
        iconView.onPress = { [weak self] in self?.holdBegan() }
        iconView.onRelease = { [weak self] in self?.onHoldEnded?() }
        p.contentView = iconView
        self.iconView = iconView
        p.orderFrontRegardless()
        iconView.arrive()
        icon = p
        scheduleFray()
    }

    private func scheduleFray() {
        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: Self.restTime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fray() }
        }
    }

    private func fray() {
        guard !opened else { return }
        lasso?.fray(duration: Self.frayTime)
        iconView?.leave(duration: Self.frayTime)
        fraying = Timer.scheduledTimer(withTimeInterval: Self.frayTime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    /// The pointer reached the icon: hold the thread in focus, and undo a fray in progress.
    private func pointerEntered() {
        guard !opened else { return }
        fraying?.invalidate()
        fraying = nil
        expiry?.invalidate()
        iconView?.restore()
        lasso?.apply(.focused)
    }

    private func pointerLeft() {
        guard !opened, icon != nil else { return }
        lasso?.apply(.resting)
        scheduleFray()
    }

    /// A press anywhere except on the icon withdraws an offer that hasn't been opened.
    /// Once opened, Llasso's own click handling decides.
    func pressed(at point: CGPoint) {
        guard let icon, !opened, !icon.frame.contains(point) else { return }
        dismiss()
    }

    // For the look test: the pointer on the icon, and the fray starting now.
    func testHover() { iconView?.testHover(); pointerEntered() }
    func testFray() { expiry?.invalidate(); fray() }

    var isShowing: Bool { icon != nil }
    var isOpened: Bool { icon != nil && opened }
    var window: NSWindow? { icon }

    func setRecording(_ on: Bool) { iconView?.recording = on }

    /// Centre of the icon on screen, while it shows.
    var iconCentre: CGPoint? { icon.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } }

    /// Move the icon so it sits on the prompt's mic.
    func moveIcon(to centre: CGPoint) {
        guard let icon else { return }
        icon.setFrameOrigin(CGPoint(x: centre.x - icon.frame.width / 2, y: centre.y - icon.frame.height / 2))
    }

    private func markOpened() {
        expiry?.invalidate()
        expiry = nil
        fraying?.invalidate()
        fraying = nil
        outline?.orderOut(nil)
        outline = nil
        lasso = nil
        opened = true
        iconView?.restore()
        iconView?.opened = true
    }

    private func open() {
        guard !opened else { return }
        markOpened()
        onOpen?(box)
    }

    private func holdBegan() {
        markOpened()
        onHoldBegan?(box)
    }

    func dismiss() {
        expiry?.invalidate()
        expiry = nil
        fraying?.invalidate()
        fraying = nil
        outline?.orderOut(nil)
        outline = nil
        lasso = nil
        icon?.orderOut(nil)
        icon = nil
        iconView = nil
        opened = false
    }
}

/// The Llasso mark on a 34pt glass disc. Hover a quarter of a second to open the prompt;
/// press and hold to talk, release to send. Opened, the disc goes and the bare mark sits on
/// the prompt's mic; while recording, dotted rings ripple out from it.
private final class OfferIcon: NSView {
    var onHover: (() -> Void)?
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var opened = false { didSet { toolTip = opened ? "Hold to talk, release to send" : toolTip; update() } }
    var recording = false { didSet { update() } }
    private var hoverTimer: Timer?
    private var hovering = false { didSet { update() } }

    static let disc: CGFloat = 34
    private let body = CALayer()
    private let discLayer = CAShapeLayer()
    private let markFill = CAShapeLayer()
    private let markDots = CAShapeLayer()
    private let rings = [CAShapeLayer(), CAShapeLayer()]
    private var dust: CALayer?
    private var leaving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let d = Self.disc

        for (i, ring) in rings.enumerated() {
            let r: CGFloat = i == 0 ? 22 : 29
            ring.path = CGPath(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r), transform: nil)
            ring.frame = bounds
            ring.fillColor = nil
            ring.strokeColor = Palette.gold.cgColor
            ring.lineWidth = 1
            ring.lineCap = .round
            ring.lineDashPattern = [0.01, i == 0 ? 3.5 : 4.5]
            ring.opacity = 0
            ring.contentsScale = scale
            layer?.addSublayer(ring)
        }

        body.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        body.position = centre
        body.contentsScale = scale
        layer?.addSublayer(body)

        discLayer.path = CGPath(ellipseIn: body.bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        discLayer.lineWidth = 1
        discLayer.shadowOffset = .zero
        discLayer.contentsScale = scale
        body.addSublayer(discLayer)

        let markRect = CGRect(x: (d - 24) / 2, y: (d - 24) / 2, width: 24, height: 24)
        let mark = LassoMark.path(in: markRect)
        markFill.path = mark
        markFill.contentsScale = scale
        body.addSublayer(markFill)
        markDots.path = mark
        markDots.fillColor = nil
        markDots.strokeColor = Palette.gold.cgColor
        markDots.lineWidth = 0.9
        markDots.lineCap = .round
        markDots.lineDashPattern = [0.01, 1.6]
        markDots.opacity = 0
        markDots.contentsScale = scale
        body.addSublayer(markDots)

        addTrackingArea(NSTrackingArea(rect: bounds.insetBy(dx: (bounds.width - d) / 2 - 3, dy: (bounds.height - d) / 2 - 3),
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
        toolTip = "Rest here to ask Llasso, or hold to talk"
        colour()
        update(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicks only count on the disc, not the transparent room round it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        return hypot(local.x - c.x, local.y - c.y) <= Self.disc / 2 + 4 ? self : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colour()
        update(animated: false)
    }

    private func colour() {
        let dark = effectiveAppearance.isDark
        effectiveAppearance.performAsCurrentDrawingAppearance {
            markFill.fillColor = Palette.accent.cgColor
        }
        discLayer.fillColor = (dark ? NSColor(white: 0.04, alpha: 0.72) : NSColor(white: 1, alpha: 0.86)).cgColor
        discLayer.strokeColor = Palette.gold.withAlphaComponent(dark ? 0.6 : 0.65).cgColor
    }

    /// Dotted outline of the mark traces in, then the disc frosts in behind it.
    func arrive() {
        let now = CACurrentMediaTime()
        markDots.opacity = 1
        let trace = CABasicAnimation(keyPath: "strokeEnd")
        trace.fromValue = 0
        trace.toValue = 1
        trace.duration = 0.28
        trace.timingFunction = CAMediaTimingFunction(name: .easeOut)
        markDots.add(trace, forKey: "trace")
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 1
        out.toValue = 0
        out.beginTime = now + 0.3
        out.duration = 0.15
        out.fillMode = .backwards
        markDots.add(out, forKey: "out")
        markDots.opacity = 0
        let frost = CABasicAnimation(keyPath: "opacity")
        frost.fromValue = 0
        frost.beginTime = now + 0.2
        frost.duration = 0.18
        frost.fillMode = .backwards
        discLayer.add(frost, forKey: "frost")
        markFill.add(frost, forKey: "frost")
    }

    /// The disc fades first; the mark falls back to dotted thread that sparkles away.
    func leave(duration: TimeInterval) {
        guard !leaving, let host = layer else { return }
        leaving = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        discLayer.opacity = 0
        markFill.opacity = 0
        CATransaction.commit()
        let mark = LassoMark.path(in: CGRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24))
        dust = Dust.scatter(along: mark, gap: 1.6, dotSize: 0.9, colour: Palette.gold, opacity: 0.8,
                            drift: 12, duration: duration, into: host)
    }

    func restore() {
        guard leaving else { return }
        leaving = false
        dust?.removeFromSuperlayer()
        dust = nil
        update(animated: false)
    }

    private func update(animated: Bool = true) {
        guard !leaving else { return }
        let dark = effectiveAppearance.isDark
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.16 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        let lit = hovering || recording
        body.opacity = opened || lit ? 1 : 0.7
        let swell: CGFloat = hovering && !opened ? 1.15 : 1
        body.transform = CATransform3DMakeScale(swell, swell, 1)
        discLayer.opacity = opened ? 0 : 1
        markFill.opacity = 1
        discLayer.shadowColor = lit ? Palette.gold.cgColor : NSColor.black.cgColor
        discLayer.shadowRadius = lit ? 9 : (dark ? 0 : 5)
        discLayer.shadowOpacity = lit ? 0.6 : (dark ? 0 : 0.14)
        discLayer.shadowOffset = lit || dark ? .zero : CGSize(width: 0, height: -2)
        CATransaction.commit()
        recording ? startRings() : stopRings()
    }

    private func startRings() {
        guard rings[0].animation(forKey: "ripple") == nil else { return }
        for (i, ring) in rings.enumerated() {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.75, 0]
            fade.keyTimes = [0, 0.3, 1]
            fade.duration = 1.1
            fade.repeatCount = .infinity
            fade.beginTime = CACurrentMediaTime() + Double(i) * 0.35
            ring.add(fade, forKey: "ripple")
        }
    }

    private func stopRings() {
        rings.forEach { $0.removeAnimation(forKey: "ripple") }
    }

    func testHover() { hovering = true }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        onEnter?()
        guard !opened else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.onHover?()
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        hoverTimer?.invalidate()
        onExit?()
    }

    override func mouseDown(with event: NSEvent) {
        hoverTimer?.invalidate()
        onPress?()
    }

    override func mouseUp(with event: NSEvent) {
        onRelease?()
    }
}
