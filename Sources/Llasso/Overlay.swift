import AppKit

enum Palette {
    static let ink = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.047, alpha: 1)       // #0E0E0C
    static let paper = NSColor(srgbRed: 0.949, green: 0.941, blue: 0.918, alpha: 1)     // #F2F0EA
    static let amber = NSColor(srgbRed: 1.0, green: 0.690, blue: 0.0, alpha: 1)         // #FFB000
    static let muted = NSColor(srgbRed: 0.541, green: 0.529, blue: 0.498, alpha: 1)     // #8A877F
    static let line = NSColor(srgbRed: 0.2, green: 0.192, blue: 0.173, alpha: 1)        // #33312C
    static let ok = NSColor(srgbRed: 0.239, green: 0.863, blue: 0.518, alpha: 1)        // #3DDC84
}

/// A borderless window covering one display. It dims the screen and lets the user drag a box.
final class OverlayWindow: NSWindow {
    let selectionView: SelectionView
    let screenRef: NSScreen

    init(screen: NSScreen) {
        screenRef = screen
        selectionView = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = selectionView
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draws the light dim and the gold thread while dragging, and reports the drag.
/// Once a box is chosen, a LassoView holds it in focus while the prompt is open.
final class SelectionView: NSView {
    enum Mode { case selecting, holding, outline }

    var mode: Mode = .selecting {
        didSet {
            window?.ignoresMouseEvents = mode == .outline
            updateLasso()
            needsDisplay = true
        }
    }
    /// Selection in this view's coordinates.
    private(set) var selection: CGRect?
    private var anchor: CGPoint?
    /// Where the pointer is while dragging: the bead of light leads from here.
    private var head: CGPoint?
    private var lasso: LassoView?

    var onPointerDown: (() -> Void)?
    /// Selection in view coordinates when the drag ends.
    var onSelection: ((CGRect) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if mode == .selecting { addCursorRect(bounds, cursor: .crosshair) }
    }

    func clear() {
        selection = nil
        anchor = nil
        head = nil
        updateLasso()
        needsDisplay = true
    }

    func show(selection rect: CGRect) {
        selection = rect
        updateLasso()
        needsDisplay = true
    }

    private func updateLasso() {
        guard mode != .selecting, let selection else {
            lasso?.removeFromSuperview()
            lasso = nil
            return
        }
        let frame = selection.insetBy(dx: -LassoView.margin, dy: -LassoView.margin)
        if let lasso, lasso.frame == frame { return }
        lasso?.removeFromSuperview()
        let view = LassoView(frame: frame)
        view.apply(.focused, animated: false)
        addSubview(view)
        lasso = view
    }

    override func mouseDown(with event: NSEvent) { dragBegan(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { dragMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { dragEnded() }

    // The drag can come from this view's own mouse events (after the hotkey) or from
    // the right-button gesture tap, which feeds points in this view's coordinates.

    func dragBegan(at point: CGPoint) {
        guard mode == .selecting else { return }
        anchor = point
        head = point
        selection = nil
        onPointerDown?()
        needsDisplay = true
    }

    func dragMoved(to p: CGPoint) {
        guard mode == .selecting, let anchor else { return }
        head = p
        selection = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                           width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
        needsDisplay = true
    }

    func dragEnded() {
        guard mode == .selecting else { return }
        anchor = nil
        head = nil
        guard let selection, selection.width >= 12, selection.height >= 12 else {
            // A click or a tiny drag: keep waiting for a real box.
            self.selection = nil
            needsDisplay = true
            onSelection?(.zero)
            return
        }
        onSelection?(selection)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard mode == .selecting else {
            // Nearly clear, so clicks still land here and Llasso can tell a click away.
            NSColor(white: 0, alpha: 0.01).setFill()
            bounds.fill()
            return
        }
        let dim = NSBezierPath(rect: bounds)
        if let selection { dim.append(NSBezierPath(rect: selection)) }
        dim.windingRule = .evenOdd
        NSColor(white: 0.03, alpha: 0.18).setFill()
        dim.fill()
        guard let selection else {
            drawHint()
            return
        }
        // The thread at full gold while you draw, with a bead of light at the pointer.
        let thread = NSBezierPath(roundedRect: selection, xRadius: 8, yRadius: 8)
        thread.lineWidth = 1
        thread.lineCapStyle = .round
        thread.setLineDash([0.01, LassoView.restingGap], count: 2, phase: 0)
        NSGraphicsContext.saveGraphicsState()
        NSAffineTransform(transform: AffineTransform(translationByX: 0.5, byY: -0.6)).concat()
        NSColor(white: 0, alpha: 0.3).setStroke()
        thread.stroke()
        NSGraphicsContext.restoreGraphicsState()
        Palette.gold.setStroke()
        thread.stroke()
        if let head { drawBead(at: head) }
    }

    private func drawBead(at p: CGPoint) {
        let glow = NSGradient(colors: [Palette.glint.withAlphaComponent(0.7), Palette.glint.withAlphaComponent(0)])
        glow?.draw(in: NSBezierPath(ovalIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), relativeCenterPosition: .zero)
        Palette.glint.setFill()
        NSBezierPath(ovalIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)).fill()
    }

    private func drawHint() {
        let text = "Drag a box round anything  ·  Esc to cancel"
        let dark = effectiveAppearance.isDark
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.08, alpha: 1),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pill = CGRect(x: bounds.midX - size.width / 2 - 18, y: bounds.maxY - 120,
                          width: size.width + 36, height: size.height + 18)
        let shape = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        (dark ? NSColor(white: 0.06, alpha: 0.82) : NSColor(white: 1, alpha: 0.9)).setFill()
        shape.fill()
        Palette.gold.withAlphaComponent(0.6).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        (text as NSString).draw(at: CGPoint(x: pill.minX + 18, y: pill.minY + 9), withAttributes: attrs)
    }
}

/// A floating, borderless panel for the prompt pill and the result card. It can take
/// keyboard focus without activating any other window.
final class FloatingPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // The glass draws its own soft shadow or glow inside the window's margin.
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { true }

    /// Place the panel beside a box (AppKit global coordinates): below it if there is room,
    /// otherwise above, otherwise inside its bottom edge. Kept on the box's screen.
    func place(near box: CGRect, on screen: NSScreen) {
        let size = frame.size
        let m = Glass.margin
        let visible = screen.visibleFrame.insetBy(dx: -m, dy: -m)
        var origin = CGPoint(x: box.minX - m, y: box.minY - 16 - size.height + m)
        if origin.y < visible.minY + 8 {
            origin.y = box.maxY + 16 - m
            if origin.y + size.height > visible.maxY - 8 {
                origin.y = box.minY + 16 - m
            }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrameOrigin(origin)
    }

    /// Place the panel so the point `offset` (from its top-left) lands on `point`, kept on screen.
    func place(_ offset: CGPoint, at point: CGPoint, on screen: NSScreen) {
        let size = frame.size
        let visible = screen.visibleFrame.insetBy(dx: -Glass.margin, dy: -Glass.margin)
        var origin = CGPoint(x: point.x - offset.x, y: point.y + offset.y - size.height)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrameOrigin(origin)
    }
}
