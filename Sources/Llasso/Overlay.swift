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

/// Draws the dim, the amber box and its handles, and reports the drag.
final class SelectionView: NSView {
    enum Mode { case selecting, holding, outline }

    var mode: Mode = .selecting {
        didSet {
            window?.ignoresMouseEvents = mode == .outline
            needsDisplay = true
        }
    }
    /// Selection in this view's coordinates.
    private(set) var selection: CGRect?
    private var anchor: CGPoint?

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
        needsDisplay = true
    }

    func show(selection rect: CGRect) {
        selection = rect
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { dragBegan(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { dragMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { dragEnded() }

    // The drag can come from this view's own mouse events (after the hotkey) or from
    // the right-button gesture tap, which feeds points in this view's coordinates.

    func dragBegan(at point: CGPoint) {
        guard mode == .selecting else { return }
        anchor = point
        selection = nil
        onPointerDown?()
        needsDisplay = true
    }

    func dragMoved(to p: CGPoint) {
        guard mode == .selecting, let anchor else { return }
        selection = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                           width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
        needsDisplay = true
    }

    func dragEnded() {
        guard mode == .selecting else { return }
        anchor = nil
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
        if mode != .outline {
            let dim = NSBezierPath(rect: bounds)
            if let selection { dim.append(NSBezierPath(rect: selection)) }
            dim.windingRule = .evenOdd
            NSColor(white: 0.03, alpha: 0.30).setFill()
            dim.fill()
        }
        guard let selection else {
            if mode == .selecting { drawHint() }
            return
        }
        let border = NSBezierPath(roundedRect: selection, xRadius: 6, yRadius: 6)
        border.lineWidth = 2
        if mode == .outline { border.setLineDash([6, 4], count: 2, phase: 0) }
        Palette.amber.setStroke()
        border.stroke()
        Palette.amber.setFill()
        for corner in [CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.minY)] {
            NSBezierPath(roundedRect: CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10),
                         xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawHint() {
        let text = "Drag a box round anything, and talk while you drag  ·  Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: Palette.paper,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pill = CGRect(x: bounds.midX - size.width / 2 - 18, y: bounds.maxY - 120,
                          width: size.width + 36, height: size.height + 18)
        Palette.ink.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
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
        hasShadow = true
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
        let visible = screen.visibleFrame
        var origin = CGPoint(x: box.minX, y: box.minY - 16 - size.height)
        if origin.y < visible.minY + 8 {
            origin.y = box.maxY + 16
            if origin.y + size.height > visible.maxY - 8 {
                origin.y = box.minY + 16
            }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrameOrigin(origin)
    }
}
