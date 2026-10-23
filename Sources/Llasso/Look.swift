import AppKit
import QuartzCore
import SwiftUI
import LlassoKit

// The gold-thread look (Paper: "Gold lasso — styling and motion"): a 1px string of gold dots
// round the box, the Llasso mark as the icon, and frosted glass panels edged in gold.

extension Palette {
    static let gold = NSColor(srgbRed: 0.867, green: 0.698, blue: 0.306, alpha: 1)        // #DDB24E dots
    static let glint = NSColor(srgbRed: 1.0, green: 0.957, blue: 0.82, alpha: 1)         // #FFF4D1
    /// Gold for marks and text: deeper on light glass, brighter on dark.
    static let accent = dynamic(light: NSColor(srgbRed: 0.722, green: 0.525, blue: 0.165, alpha: 1),   // #B8862A
                                dark: NSColor(srgbRed: 0.91, green: 0.769, blue: 0.416, alpha: 1))     // #E8C46A
    static let text = dynamic(light: NSColor(srgbRed: 0.078, green: 0.071, blue: 0.063, alpha: 1),
                              dark: NSColor(srgbRed: 0.961, green: 0.953, blue: 0.933, alpha: 1))
    static let subtext = dynamic(light: NSColor(white: 0.30, alpha: 1), dark: NSColor(white: 0.76, alpha: 1))
    static let faint = dynamic(light: NSColor(white: 0.45, alpha: 1), dark: NSColor(white: 0.56, alpha: 1))
    static let positive = dynamic(light: NSColor(srgbRed: 0.12, green: 0.54, blue: 0.30, alpha: 1), dark: ok)

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

// MARK: - The lasso round a box

/// The dotted gold thread round a box, in one of four states. Layer-backed so the glint and
/// the fray run on Core Animation. The view is larger than the box by `margin` on every side,
/// which leaves room for the halo and for dots drifting down as they fray.
final class LassoView: NSView {
    enum State { case resting, focused }

    static let margin: CGFloat = 26
    static let restingOpacity: Float = 0.55
    static let restingGap: CGFloat = 5
    static let focusedGap: CGFloat = 3.5

    private let shadowDots = CAShapeLayer()
    private let dots = CAShapeLayer()
    private let halo = CAShapeLayer()
    private let glint = CAShapeLayer()
    private var dust: CALayer?
    private(set) var state: State = .resting
    private(set) var fraying = false

    var boxRect: CGRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [halo, shadowDots, dots, glint] {
            l.fillColor = nil
            l.lineCap = .round
            l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer?.addSublayer(l)
        }
        shadowDots.strokeColor = NSColor(white: 0, alpha: 0.32).cgColor
        shadowDots.lineWidth = 1
        dots.strokeColor = Palette.gold.cgColor
        dots.lineWidth = 1
        halo.strokeColor = Palette.gold.withAlphaComponent(0.22).cgColor
        halo.lineWidth = 1.5
        halo.shadowColor = Palette.gold.cgColor
        halo.shadowOffset = .zero
        halo.shadowRadius = 7
        halo.shadowOpacity = 0.9
        halo.opacity = 0
        glint.strokeColor = Palette.glint.cgColor
        glint.lineWidth = 1.5
        glint.shadowColor = Palette.gold.cgColor
        glint.shadowOffset = .zero
        glint.shadowRadius = 3
        glint.shadowOpacity = 1
        glint.opacity = 0
        layout()
        apply(.resting, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let path = CGPath(roundedRect: boxRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        for l in [halo, dots, glint] { l.frame = bounds; l.path = path }
        shadowDots.frame = bounds.offsetBy(dx: 0.5, dy: -0.6)
        shadowDots.path = path
    }

    /// Close the loop from the release corner: the thread draws round in a quarter second.
    func drawOn() {
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = 0
        a.toValue = 1
        a.duration = 0.25
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        dots.add(a, forKey: "draw")
        shadowDots.add(a, forKey: "draw")
    }

    func apply(_ state: State, animated: Bool = true) {
        if fraying { restore() }
        self.state = state
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.22 : 0)
        let gap = state == .focused ? Self.focusedGap : Self.restingGap
        dots.lineDashPattern = [0.01, NSNumber(value: Double(gap))]
        shadowDots.lineDashPattern = dots.lineDashPattern
        glint.lineDashPattern = dots.lineDashPattern
        let opacity: Float = state == .focused ? 1 : Self.restingOpacity
        dots.opacity = opacity
        shadowDots.opacity = opacity * 0.9
        halo.opacity = state == .focused ? 1 : 0
        CATransaction.commit()
        state == .resting ? startGlint() : stopGlint()
    }

    /// One soft glint travels round the loop every four seconds while it rests.
    private func startGlint() {
        guard glint.animation(forKey: "lap") == nil else { return }
        let perimeter = 2 * (boxRect.width + boxRect.height)
        let span = min(0.25, 56 / max(perimeter, 1))
        glint.opacity = 0.9
        let start = CABasicAnimation(keyPath: "strokeStart")
        start.fromValue = -span
        start.toValue = 1
        let end = CABasicAnimation(keyPath: "strokeEnd")
        end.fromValue = 0
        end.toValue = 1 + span
        let lap = CAAnimationGroup()
        lap.animations = [start, end]
        lap.duration = 4
        lap.repeatCount = .infinity
        glint.add(lap, forKey: "lap")
    }

    private func stopGlint() {
        glint.removeAnimation(forKey: "lap")
        glint.opacity = 0
    }

    /// Left alone: dots let go in random order and drift down as they fade.
    func fray(duration: TimeInterval = 1.2) {
        guard !fraying, let host = layer else { return }
        fraying = true
        stopGlint()
        let gap = state == .focused ? Self.focusedGap : Self.restingGap
        let path = CGPath(roundedRect: boxRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        dust = Dust.scatter(along: path, gap: gap, dotSize: 1.2, colour: Palette.gold,
                            opacity: dots.opacity, drift: 20, duration: duration, into: host)
        dots.opacity = 0
        shadowDots.opacity = 0
        halo.opacity = 0
    }

    /// Touched mid-fray: pull the thread back to full.
    func restore() {
        guard fraying else { return }
        fraying = false
        dust?.removeFromSuperlayer()
        dust = nil
        apply(state, animated: false)
    }
}

/// Turns a dotted path into separate dots that fall away one by one.
enum Dust {
    /// Points every `gap` along a path.
    static func points(along path: CGPath, gap: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        path.copy(dashingWithPhase: 0, lengths: [0.01, gap]).applyWithBlock { el in
            if el.pointee.type == .moveToPoint { out.append(el.pointee.points[0]) }
        }
        return out
    }

    @discardableResult
    static func scatter(along path: CGPath, gap: CGFloat, dotSize: CGFloat, colour: NSColor, opacity: Float,
                        drift: CGFloat, duration: TimeInterval, into host: CALayer) -> CALayer {
        let container = CALayer()
        container.frame = host.bounds
        host.addSublayer(container)
        let now = CACurrentMediaTime()
        let fall = min(0.55, duration * 0.45)
        for p in points(along: path, gap: gap) {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
            dot.backgroundColor = colour.cgColor
            dot.position = p
            dot.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity
            fade.toValue = 0
            let sink = CABasicAnimation(keyPath: "position.y")
            sink.fromValue = p.y
            sink.toValue = p.y - drift * CGFloat.random(in: 0.5...1)
            let group = CAAnimationGroup()
            group.animations = [fade, sink]
            group.duration = fall
            group.beginTime = now + Double.random(in: 0...(duration - fall))
            group.timingFunction = CAMediaTimingFunction(name: .easeIn)
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            dot.add(group, forKey: "fray")
            container.addSublayer(dot)
        }
        return container
    }
}

/// A borderless, click-through window holding a LassoView round a box (AppKit global coordinates).
@MainActor
enum LassoWindow {
    static func make(round box: CGRect, level: NSWindow.Level = .floating) -> (NSWindow, LassoView) {
        let frame = box.insetBy(dx: -LassoView.margin, dy: -LassoView.margin)
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = level
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        let view = LassoView(frame: CGRect(origin: .zero, size: frame.size))
        w.contentView = view
        return (w, view)
    }
}

// MARK: - The mark

struct MarkShape: Shape {
    func path(in rect: CGRect) -> Path { Path(LassoMark.path(in: rect, flipped: true)) }
}

extension NSImage {
    /// The mark as a template image for the menu bar.
    static func llassoMark(height: CGFloat = 11) -> NSImage {
        let size = CGSize(width: ceil(height * LassoMark.size.width / LassoMark.size.height), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(LassoMark.path(in: rect))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Llasso"
        return image
    }
}

// MARK: - Glass

/// Behind-window blur for SwiftUI panels.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

extension Color {
    static let llGold = Color(nsColor: Palette.accent)
    static let llDot = Color(nsColor: Palette.gold)
    static let llText = Color(nsColor: Palette.text)
    static let llSub = Color(nsColor: Palette.subtext)
    static let llFaint = Color(nsColor: Palette.faint)
    static let llPositive = Color(nsColor: Palette.positive)
    static let llWell = Color(nsColor: Palette.dynamic(light: NSColor(white: 0, alpha: 0.05),
                                                       dark: NSColor(white: 1, alpha: 0.07)))
    /// Text on a gold chip.
    static let llOnGold = Color(nsColor: Palette.dynamic(light: .white,
                                                         dark: NSColor(srgbRed: 0.078, green: 0.071, blue: 0.063, alpha: 1)))
    static let llHair = Color(nsColor: Palette.dynamic(light: NSColor(white: 0, alpha: 0.16),
                                                       dark: NSColor(white: 1, alpha: 0.18)))
    static let llDanger = Color(nsColor: Palette.dynamic(light: NSColor(srgbRed: 0.75, green: 0.25, blue: 0.2, alpha: 1),
                                                         dark: NSColor(srgbRed: 0.95, green: 0.55, blue: 0.5, alpha: 1)))
}

/// Room round a glass panel for its shadow or glow; the panel's window is this much larger.
enum Glass {
    static let margin: CGFloat = 34
    static let radius: CGFloat = 16
}

/// Frosted glass that follows the system theme: white glass with a soft shadow in light mode,
/// black glass with a soft gold glow in dark mode, both edged with a gold hairline.
/// `amount` (0...1) frosts the glass in; `edge` fades in the solid hairline.
struct GlassBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = Glass.radius
    var amount: Double = 1
    var edge: Double = 1

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        return content
            .background(
                ZStack {
                    VisualEffect(material: dark ? .hudWindow : .popover)
                    shape.fill(dark ? Color.black.opacity(0.42) : Color.white.opacity(0.55))
                    shape.strokeBorder(Color.llDot.opacity(0.10), lineWidth: 8).blur(radius: 8)   // inner gold light
                }
                .clipShape(shape)
                .opacity(amount)
            )
            .overlay(shape.strokeBorder(Color.llDot.opacity(dark ? 0.55 : 0.6), lineWidth: 1).opacity(edge))
            .compositingGroup()
            .shadow(color: dark ? Color.llDot.opacity(0.22 * amount) : Color.black.opacity(0.13 * amount),
                    radius: dark ? 12 : 14, x: 0, y: dark ? 0 : 7)
            .shadow(color: dark ? Color.llDot.opacity(0.07 * amount) : Color.black.opacity(0.06 * amount),
                    radius: dark ? 20 : 3, x: 0, y: dark ? 0 : 1)
            .padding(Glass.margin)
    }
}

extension View {
    func glass(radius: CGFloat = Glass.radius, amount: Double = 1, edge: Double = 1) -> some View {
        modifier(GlassBackground(radius: radius, amount: amount, edge: edge))
    }
}
