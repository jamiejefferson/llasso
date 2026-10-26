import AppKit
import QuartzCore
import SwiftUI
import LlassoKit

// The look: a pulsing marching-ants marquee in white and black round the box, with a spark of
// light that runs round it, and clean white or black frosted glass for the panels.

extension Palette {
    /// The marquee's dashes and the spark that runs round it.
    static let ant = NSColor.white
    static let glint = NSColor.white
    static let text = dynamic(light: NSColor(srgbRed: 0.078, green: 0.071, blue: 0.063, alpha: 1),
                              dark: NSColor(srgbRed: 0.961, green: 0.953, blue: 0.933, alpha: 1))
    static let subtext = dynamic(light: NSColor(white: 0.30, alpha: 1), dark: NSColor(white: 0.76, alpha: 1))
    static let faint = dynamic(light: NSColor(white: 0.45, alpha: 1), dark: NSColor(white: 0.56, alpha: 1))
    /// "Needs you": the accent colour chosen in System Settings, as macOS uses for attention.
    static let alert = NSColor.controlAccentColor
    static let positive = dynamic(light: NSColor(srgbRed: 0.12, green: 0.54, blue: 0.30, alpha: 1), dark: ok)

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

// MARK: - The lasso round a box

/// The marquee round a box: marching ants in the old Photoshop style, white dashes over a dark
/// line so it reads on any page, pulsing gently, with a spark of light running round the loop. Layer-backed so the march, the pulse and the
/// fray run on Core Animation. The view is larger than the box by `margin` on every side, which
/// leaves room for the dashes drifting out as they fray.
final class LassoView: NSView {
    enum State { case resting, focused }

    static let margin: CGFloat = 26
    /// Line weight, and the length of each dash and each gap.
    static let lineWidth: CGFloat = 1
    static let dash: CGFloat = 4
    static let corner: CGFloat = 2
    /// One march of a dash and a gap, in seconds; resting is slower.
    static let marchFocused: CFTimeInterval = 0.45
    static let marchResting: CFTimeInterval = 0.9
    /// The pulse dips the marquee to this opacity and back every `pulse` seconds.
    static let pulseLow: Float = 0.55
    static let pulse: CFTimeInterval = 1.6
    /// One lap of the spark, in seconds, and how much of the loop it lights at once.
    static let sparkLap: CFTimeInterval = 2.4
    static let sparkLength: CGFloat = 0.07

    private let group = CALayer()
    private let base = CAShapeLayer()
    private let ants = CAShapeLayer()
    private let spark = CAShapeLayer()
    private var dust: CALayer?
    private(set) var state: State = .resting
    private(set) var fraying = false

    var boxRect: CGRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }
    static func path(round rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(group)
        for l in [base, ants, spark] {
            l.fillColor = nil
            l.lineWidth = Self.lineWidth
            l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            group.addSublayer(l)
        }
        base.strokeColor = NSColor(white: 0, alpha: 0.6).cgColor
        ants.strokeColor = Palette.ant.cgColor
        spark.strokeColor = Palette.glint.cgColor
        spark.lineWidth = 1.6
        spark.lineCap = .round
        spark.shadowColor = Palette.glint.cgColor
        spark.shadowOffset = .zero
        spark.shadowRadius = 3
        spark.shadowOpacity = 0.9
        spark.strokeStart = 0
        spark.strokeEnd = 0
        ants.lineDashPattern = [NSNumber(value: Double(Self.dash)), NSNumber(value: Double(Self.dash))]
        layout()
        apply(.resting, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        group.frame = bounds
        let path = Self.path(round: boxRect.insetBy(dx: 0.5, dy: 0.5))
        for l in [base, ants, spark] { l.frame = bounds; l.path = path }
    }

    /// Close the loop from the release corner: the marquee draws round in a quarter second.
    func drawOn() {
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = 0
        a.toValue = 1
        a.duration = 0.25
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ants.add(a, forKey: "draw")
        base.add(a, forKey: "draw")
    }

    func apply(_ state: State, animated: Bool = true) {
        if fraying { restore() }
        self.state = state
        march(state == .focused ? Self.marchFocused : Self.marchResting)
        let p = CABasicAnimation(keyPath: "opacity")
        p.fromValue = 1
        p.toValue = state == .focused ? (1 + Self.pulseLow) / 2 : Self.pulseLow
        p.duration = Self.pulse / 2
        p.autoreverses = true
        p.repeatCount = .infinity
        p.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.add(p, forKey: "pulse")
    }

    private func march(_ duration: CFTimeInterval) {
        let a = CABasicAnimation(keyPath: "lineDashPhase")
        a.fromValue = 0
        a.toValue = -2 * Self.dash
        a.duration = duration
        a.repeatCount = .infinity
        ants.add(a, forKey: "march")
        run()
    }

    /// The spark: a short bright stretch of thread that laps the box, trailing a soft glow.
    private func run() {
        guard spark.animation(forKey: "run") == nil else { return }
        let head = CABasicAnimation(keyPath: "strokeEnd")
        head.fromValue = Self.sparkLength
        head.toValue = 1
        let tail = CABasicAnimation(keyPath: "strokeStart")
        tail.fromValue = 0
        tail.toValue = 1 - Self.sparkLength
        let lap = CAAnimationGroup()
        lap.animations = [head, tail]
        lap.duration = Self.sparkLap
        lap.repeatCount = .infinity
        lap.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        spark.add(lap, forKey: "run")
    }

    /// Left alone: the dashes break into specks that drift away outward, in random order.
    func fray(duration: TimeInterval = 1.2) {
        guard !fraying, let host = layer else { return }
        fraying = true
        dust = Dust.scatter(along: Self.path(round: boxRect), gap: Self.dash, dotSize: 1.4, colour: Palette.ant,
                            opacity: 1, drift: 12, duration: duration, into: host)
        group.removeAnimation(forKey: "pulse")
        group.opacity = 0
    }

    /// Touched mid-fray: bring the marquee back.
    func restore() {
        guard fraying else { return }
        fraying = false
        dust?.removeFromSuperlayer()
        dust = nil
        group.opacity = 1
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

    /// Each dot brightens a touch, then drifts away outward from the middle of the path, at a random moment
    /// within `duration`. `drift` is how far it travels.
    @discardableResult
    static func scatter(along path: CGPath, gap: CGFloat, dotSize: CGFloat, colour: NSColor, opacity: Float,
                        drift: CGFloat, duration: TimeInterval, into host: CALayer) -> CALayer {
        let container = CALayer()
        container.frame = host.bounds
        host.addSublayer(container)
        let now = CACurrentMediaTime()
        let life = min(0.6, duration * 0.5)
        let bounds = path.boundingBoxOfPath
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        for (i, p) in points(along: path, gap: gap).enumerated() {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
            dot.backgroundColor = colour.cgColor
            dot.position = p
            dot.opacity = 0
            // The odd dot catches the light as it goes.
            if i % 12 == 0 {
                dot.shadowColor = Palette.glint.cgColor
                dot.shadowOffset = .zero
                dot.shadowRadius = 1.5
                dot.shadowOpacity = 0.6
            }
            // Outward from the middle, give or take 20 degrees.
            let angle = atan2(p.y - centre.y, p.x - centre.x) + CGFloat.random(in: -0.35...0.35)
            let distance = drift * CGFloat.random(in: 0.5...1.15)
            let end = CGPoint(x: p.x + cos(angle) * distance, y: p.y + sin(angle) * distance)

            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: p)
            move.toValue = NSValue(point: end)
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.4, 1)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [opacity, opacity, 0]
            fade.keyTimes = [0, 0.15, 1]
            let flare = CAKeyframeAnimation(keyPath: "transform.scale")
            flare.values = [1, 1.3, 0.5]
            flare.keyTimes = [0, 0.15, 1]
            let shine = CAKeyframeAnimation(keyPath: "backgroundColor")
            shine.values = [colour.cgColor, colour.blended(withFraction: 0.35, of: Palette.glint)?.cgColor ?? colour.cgColor, colour.cgColor]
            shine.keyTimes = [0, 0.15, 1]
            let group = CAAnimationGroup()
            group.animations = [move, fade, flare, shine]
            group.duration = life
            group.beginTime = now + Double.random(in: 0...(duration - life))
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            dot.add(group, forKey: "sparkle")
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
        // The box stays on the desktop it was drawn on.
        w.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
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
    /// Dotted threads, level bars and the working arc.
    static let llThread = Color(nsColor: Palette.faint)
    static let llAlert = Color(nsColor: Palette.alert)
    static let llText = Color(nsColor: Palette.text)
    static let llSub = Color(nsColor: Palette.subtext)
    static let llFaint = Color(nsColor: Palette.faint)
    static let llPositive = Color(nsColor: Palette.positive)
    static let llWell = Color(nsColor: Palette.dynamic(light: NSColor(white: 0, alpha: 0.05),
                                                       dark: NSColor(white: 1, alpha: 0.07)))
    /// The Llasso mark, primary buttons and selected chips: solid black on light glass, solid white on dark.
    static let llInk = Color(nsColor: Palette.text)
    /// Text on an ink button.
    static let llOnInk = Color(nsColor: Palette.dynamic(light: .white, dark: NSColor(white: 0.06, alpha: 1)))
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

/// Frosted glass that follows the system theme: clean white glass in light mode, clean black
/// glass in dark mode, each with a neutral hairline and a soft shadow. `amount` (0...1) frosts the glass in; `edge` fades in the hairline.
struct GlassBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = Glass.radius
    var amount: Double = 1
    var edge: Double = 1
    var padded = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        return content
            .background(
                ZStack {
                    VisualEffect(material: dark ? .hudWindow : .popover)
                    // Opaque enough that busy pages behind don't tint the glass.
                    shape.fill(dark ? Color.black.opacity(0.72) : Color.white.opacity(0.86))
                }
                .clipShape(shape)
                .opacity(amount)
            )
            .overlay(shape.strokeBorder(Color.llHair, lineWidth: 0.5).opacity(edge))
            .compositingGroup()
            .shadow(color: Color.black.opacity((dark ? 0.45 : 0.14) * amount), radius: 16, x: 0, y: 8)
            .shadow(color: Color.black.opacity((dark ? 0.3 : 0.06) * amount), radius: 2, x: 0, y: 1)
            .padding(padded ? Glass.margin : 0)
    }
}

extension View {
    func glass(radius: CGFloat = Glass.radius, amount: Double = 1, edge: Double = 1) -> some View {
        modifier(GlassBackground(radius: radius, amount: amount, edge: edge))
    }

    /// The same glass as a capsule, with no room round it; for the Working chips.
    func chipGlass() -> some View {
        modifier(GlassBackground(radius: 17, padded: false))
    }
}
