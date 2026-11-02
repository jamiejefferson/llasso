import AppKit
import LlassoKit

/// Quick looks at the screen through Jev, which reads pictures from 1.14 on: whether a change
/// shows, whether something is on screen, and where a control is. Each look takes about half a
/// second. Jev's picture reading is experimental, so every look can come back nil, and then
/// Llasso carries on as it would without it.
@MainActor
enum Glance {
    static var on: Bool { ModelStore.shared.useJevLooks && Settings.shared.hasKey }
    static let timeout: TimeInterval = 3
    /// Jev refuses pictures outside these sides, and doesn't resize them itself.
    static let largest: CGFloat = 1568
    static let smallest: CGFloat = 320

    /// The screen now, as the job's first capture shows it.
    static func screen(_ box: (rect: CGRect, screen: NSScreen)) async -> Data? {
        try? await Capture.overview(screen: box.screen, selection: box.rect)
    }

    /// How likely the answer is yes. `state` holds labels and pictures in order.
    static func yes(_ question: String, state: [Any]) async -> Double? {
        let answers = try? await Settings.shared.client.decide(
            state: state, questions: ["q": ["type": "noul", "instructions": question]], timeout: timeout).answers
        return (answers?["q"] as? [String: Any])?["noul"] as? Double
    }

    /// One of `options` and how likely Jev thinks it is.
    static func choose(_ question: String, options: [String], state: [Any]) async -> (String, Double)? {
        var criteria: [String: String] = [:]
        for (i, o) in options.enumerated() { criteria["o\(i + 1)"] = o }
        guard let a = try? await Settings.shared.client.decide(
                state: state, questions: ["q": ["type": "choice", "instructions": question, "criteria": criteria]], timeout: timeout).answers,
              let q = a["q"] as? [String: Any], let id = q["choice"] as? String, let picked = criteria[id] else { return nil }
        let p = (q["probabilities"] as? [String: Double])?[id] ?? q["confidence"] as? Double ?? 0
        return (picked, p)
    }

    /// Whether `change` shows on screen, comparing a look from before it with one from after.
    /// Apps can take a moment to redraw, so with `retry` a no is asked once more a second later.
    static func landed(_ change: String, before: Data, box: (rect: CGRect, screen: NSScreen), retry: Bool = true) async -> Double? {
        let question = "Llasso has just tried to make this change on a Mac: \(change). The amber outline marks the area the user boxed. "
            + "Compare the screenshot from before with the one from after. Does the after screenshot show that change made?"
        var p: Double?
        for wait in retry ? [0.4, 1.0] : [0.4] {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let after = await screen(box) else { return nil }
            p = await yes(question, state: ["Before:", Jev.image(before), "After:", Jev.image(after)])
            if (p ?? 0) >= 0.5 { break }
            // The check test keeps what Jev saw when it says no, to tell a miss from a blank capture.
            if CommandLine.arguments.contains("--checktest") {
                let stamp = Int(Date().timeIntervalSince1970 * 10)
                try? before.write(to: History.folder.appendingPathComponent("checktest-no-\(stamp)-before.png"))
                try? after.write(to: History.folder.appendingPathComponent("checktest-no-\(stamp)-after.png"))
            }
        }
        return p
    }

    /// Where `target` sits in a picture, as fractions of it, and its size, once a close-up
    /// agrees. Nil when Jev can't place it or the close-up says it isn't there: Jev's boxes can
    /// land one along in a row of look-alike buttons, and only the close-up catches that.
    static func find(_ target: String, in png: Data) async -> CGRect? {
        guard let image = NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let whole = fitted(image) else { return nil }
        guard let a = try? await Settings.shared.client.decide(
                state: ["A picture from a Mac screen:", Jev.image(whole.png)],
                questions: ["target": ["type": "box", "instructions": target + " in the picture"]], timeout: timeout).answers,
              let b = Jev.box(a["target"]) else { return nil }
        // Back from the padded canvas to the picture itself.
        let f = whole.inner
        let box = CGRect(x: (b.minX - f.minX) / f.width, y: (b.minY - f.minY) / f.height,
                         width: b.width / f.width, height: b.height / f.height)
        guard (0...1).contains(box.midX), (0...1).contains(box.midY),
              let p = await shows(target, at: CGPoint(x: box.midX, y: box.midY), size: box.size, in: image) else { return nil }
        Log.write("glance: \(target.prefix(40)) at \(String(format: "%.2f,%.2f", box.midX, box.midY)), close-up \(String(format: "%.2f", p))")
        return p >= 0.5 ? box : nil
    }

    /// How likely a close-up of `size` round `point` (both fractions of the picture) shows
    /// `target`. The close-up is cut tight and set alone on a plain canvas, so a neighbour
    /// can't answer for it.
    static func shows(_ target: String, at point: CGPoint, size: CGSize, in image: CGImage) async -> Double? {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let w = max(size.width * W * 1.6, 24), h = max(size.height * H * 1.6, 24)
        let rect = CGRect(x: point.x * W - w / 2, y: point.y * H - h / 2, width: w, height: h)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
        guard !rect.isEmpty, let crop = image.cropping(to: rect), let close = fitted(crop, enlarge: true) else { return nil }
        return await yes("Is the thing at the very centre of this close-up " + target + "?",
                         state: ["A close-up cut from a Mac screen:", Jev.image(close.png)])
    }

    /// The picture within Jev's sizes: scaled down past the largest side, and set on a plain
    /// canvas when a side falls short. `inner` is where the picture sits, in fractions of the canvas.
    /// `enlarge` scales a small cut-out up to about 600 px across first, so its text can be read.
    static func fitted(_ image: CGImage, enlarge: Bool = false) -> (png: Data, inner: CGRect)? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let k = min(enlarge ? min(4, 600 / max(w, h)) : 1, largest / max(w, h))
        let size = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
        let canvas = CGSize(width: max(size.width, smallest), height: max(size.height, smallest))
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: canvas))
        ctx.interpolationQuality = .high
        let origin = CGPoint(x: ((canvas.width - size.width) / 2).rounded(), y: ((canvas.height - size.height) / 2).rounded())
        ctx.draw(image, in: CGRect(origin: origin, size: size))
        guard let out = ctx.makeImage(), let png = try? Capture.png(out) else { return nil }
        // CGContext is bottom-left origin; the inner frame is top-left, like Jev's boxes.
        let inner = CGRect(x: origin.x / canvas.width, y: (canvas.height - origin.y - size.height) / canvas.height,
                           width: size.width / canvas.width, height: size.height / canvas.height)
        return (png, inner)
    }
}
