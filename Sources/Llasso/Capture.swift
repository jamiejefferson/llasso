import AppKit
import ApplicationServices
import ScreenCaptureKit
import LlassoKit

enum CaptureError: Error, LocalizedError {
    case noDisplay
    case encode

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Llasso couldn't find that display to capture."
        case .encode: return "Llasso couldn't encode the capture."
        }
    }
}

/// The pixels Llasso sends: the boxed area, and the whole screen scaled down with the box outlined.
struct Capture {
    var crop: Data
    var screen: Data

    /// Capture one display, leaving out Llasso's own windows (overlay, pill, card).
    static func take(screen: NSScreen, selection: CGRect) async throws -> Capture {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { throw CaptureError.noDisplay }
        let displayID = CGDirectDisplayID(number.uint32Value)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw CaptureError.noDisplay }
        let ownApps = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = screen.backingScaleFactor
        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(display.width) * scale)
        cfg.height = Int(CGFloat(display.height) * scale)
        cfg.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)

        let imageSize = CGSize(width: image.width, height: image.height)
        let local = selection.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let cropRect = Geometry.pixelCrop(selection: local, screenSize: screen.frame.size, imageSize: imageSize)
        guard let cropped = image.cropping(to: cropRect) else { throw CaptureError.encode }

        let cropPNG = try png(resized(cropped, maxEdge: 2000, outline: nil))
        let screenPNG = try png(resized(image, maxEdge: 1400, outline: cropRect))
        return Capture(crop: cropPNG, screen: screenPNG)
    }

    /// Scale an image to fit `maxEdge`, optionally drawing an amber outline round
    /// `outline` (given in the source image's top-left pixel coordinates).
    static func resized(_ image: CGImage, maxEdge: CGFloat, outline: CGRect?) throws -> CGImage {
        let src = CGSize(width: image.width, height: image.height)
        let dst = Geometry.fit(src, maxEdge: maxEdge)
        if dst == src && outline == nil { return image }
        guard let ctx = CGContext(data: nil, width: Int(dst.width), height: Int(dst.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CaptureError.encode }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: dst))
        if let outline {
            let k = dst.width / src.width
            // CGContext is bottom-left origin; flip the top-left rect.
            let r = CGRect(x: outline.minX * k, y: dst.height - outline.maxY * k,
                           width: outline.width * k, height: outline.height * k)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.69, blue: 0, alpha: 1))
            ctx.setLineWidth(max(3, 4 * k))
            ctx.stroke(r.insetBy(dx: -2, dy: -2))
        }
        guard let out = ctx.makeImage() else { throw CaptureError.encode }
        return out
    }

    static func png(_ image: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CaptureError.encode }
        return data
    }
}

/// Reads what the operating system knows about the boxed area through the Accessibility API.
/// Without Accessibility permission it returns only the app's name.
enum ContextReader {
    static func read(app: NSRunningApplication?, selection: CGRect) -> ScreenContext {
        var ctx = ScreenContext(appName: app?.localizedName, bundleID: app?.bundleIdentifier)
        guard let app, AXIsProcessTrusted() else { return ctx }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        wake(appEl, pid: app.processIdentifier)

        if let window: AXUIElement = attr(appEl, kAXFocusedWindowAttribute) {
            ctx.windowTitle = attr(window, kAXTitleAttribute)
            if let doc: String = attr(window, kAXDocumentAttribute) {
                ctx.documentPath = URL(string: doc)?.path ?? doc
            }
        }
        if let focused: AXUIElement = attr(appEl, kAXFocusedUIElementAttribute) {
            let role: String? = attr(focused, kAXRoleAttribute)
            ctx.focusedRole = role
            if let selected: String = attr(focused, kAXSelectedTextAttribute), !selected.isEmpty {
                ctx.selectedText = selected
                ctx.canReplaceText = settable(focused, kAXSelectedTextAttribute) || editable(focused)
            } else if let found = boxedLines(appEl, selection: selection) {
                // Nothing selected: the lines of editable text the box covers can be replaced.
                ctx.selectedText = found.text
                ctx.boxedRange = found.range
                ctx.boxPoint = found.point
                ctx.canReplaceText = true
            } else if role == "AXTextField" || role == "AXComboBox" || (role == "AXTextArea" && frameInside(focused, selection)),
                      let value: String = attr(focused, kAXValueAttribute), value.count < 20_000,
                      settable(focused, kAXValueAttribute), frameIntersects(focused, selection) {
                // A plain field the box covers: its whole value can be rewritten. A text area
                // counts only when the box takes in all of it, so a note is never rewritten whole.
                ctx.fieldValue = value
                ctx.canSetField = true
            }
        }
        if ctx.selectedText == nil && !ctx.canSetField, let found = boxedLines(appEl, selection: selection) {
            ctx.selectedText = found.text
            ctx.boxedRange = found.range
            ctx.boxPoint = found.point
            ctx.canReplaceText = true
        }
        if let sheetApp = Sheets.app(for: app.bundleIdentifier) { ctx.sheet = Sheets.read(sheetApp) }

        // Sample a 5 x 5 grid of points inside the box and describe what sits there.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let r = Geometry.topLeftGlobal(selection, mainScreenHeight: mainHeight)
        var seen = Set<String>()
        for row in 0..<5 {
            for col in 0..<5 {
                let x = Float(r.minX + r.width * (CGFloat(col) + 0.5) / 5)
                let y = Float(r.minY + r.height * (CGFloat(row) + 0.5) / 5)
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(appEl, x, y, &hit) == .success, let el = hit else { continue }
                if ctx.url == nil { ctx.url = webURL(from: el) }
                if let role: String = attr(el, kAXRoleAttribute), !ctx.roles.contains(role) { ctx.roles.append(role) }
                if let line = describe(el), seen.insert(line).inserted { ctx.elements.append(line) }
            }
        }
        return ctx
    }

    /// With nothing selected, find the editable text the box covers (a note, a document, a
    /// message being written) and the whole lines inside it, so they can be replaced in place.
    static func boxedLines(_ appEl: AXUIElement, selection: CGRect) -> (text: String, range: BoxedRange, point: CGPoint)? {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let r = Geometry.topLeftGlobal(selection, mainScreenHeight: mainHeight)
        let centre = CGPoint(x: r.midX, y: r.midY)
        guard let el = textElement(appEl, at: centre) else { return nil }
        let inset = CGPoint(x: min(6, r.width / 4), y: min(6, r.height / 4))
        // A point past the end of a short line reads as index 0, so the bottom edge is sampled
        // at three places and the furthest index wins.
        guard let a = index(el, at: CGPoint(x: r.minX + inset.x, y: r.minY + inset.y)) else { return nil }
        let b = [r.minX + inset.x, r.midX, r.maxX - inset.x].compactMap { index(el, at: CGPoint(x: $0, y: r.maxY - inset.y)) }.max() ?? a
        guard let first = lineRange(el, containing: a), let last = lineRange(el, containing: max(a, b)) else { return nil }
        let range = BoxedRange(location: first.location, length: last.location + last.length - first.location)
        guard range.length > 0, range.length < 20_000, let text = string(el, range),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, range, centre)
    }

    /// The editable text element at a point (top-left global): the hit element or its nearest
    /// text-area ancestor, which must let Llasso set its selection.
    static func textElement(_ appEl: AXUIElement, at p: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appEl, Float(p.x), Float(p.y), &hit) == .success else { return nil }
        var current = hit
        for _ in 0..<8 {
            guard let node = current else { return nil }
            let role: String? = attr(node, kAXRoleAttribute)
            if role == "AXTextArea" || role == "AXTextField" || (attr(node, "AXEditableAncestor") as AXUIElement?) != nil,
               settable(node, kAXSelectedTextRangeAttribute) {
                return node
            }
            current = attr(node, kAXParentAttribute)
        }
        return nil
    }

    static func index(_ el: AXUIElement, at p: CGPoint) -> Int? {
        var point = p
        guard let v = AXValueCreate(.cgPoint, &point) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXRangeForPositionParameterizedAttribute as CFString, v, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(out as! AXValue, .cfRange, &range) ? range.location : nil
    }

    static func lineRange(_ el: AXUIElement, containing i: Int) -> BoxedRange? {
        var lineRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXLineForIndexParameterizedAttribute as CFString, i as CFNumber, &lineRef) == .success,
              let line = lineRef as? Int else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXRangeForLineParameterizedAttribute as CFString, line as CFNumber, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(out as! AXValue, .cfRange, &range) else { return nil }
        return BoxedRange(location: range.location, length: range.length)
    }

    static func string(_ el: AXUIElement, _ r: BoxedRange) -> String? {
        var cf = CFRange(location: r.location, length: r.length)
        guard let v = AXValueCreate(.cfRange, &cf) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, v, &out) == .success
        else { return nil }
        return out as? String
    }

    /// Select a range in a text element and give it focus, so the next edit lands there.
    @discardableResult
    static func select(_ r: BoxedRange, in el: AXUIElement) -> Bool {
        _ = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var cf = CFRange(location: r.location, length: r.length)
        guard let v = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    private static var woken = Set<pid_t>()

    /// Chrome and Electron apps expose their pages to Accessibility only once asked, so without
    /// this Llasso sees a browser as one flat image and can't find the selection to replace.
    /// The first time, give the app a moment to build its tree.
    static func wake(_ appEl: AXUIElement, pid: pid_t) {
        guard !woken.contains(pid) else { return }
        woken.insert(pid)
        let a = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let b = AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        if a == .success || b == .success { Thread.sleep(forTimeInterval: 0.3) }
    }

    static func settable(_ el: AXUIElement, _ name: String) -> Bool {
        var ok: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &ok) == .success && ok.boolValue
    }

    /// Web and Electron editors mark editable regions with AXEditableAncestor or a text role.
    static func editable(_ el: AXUIElement) -> Bool {
        if (attr(el, "AXEditableAncestor") as AXUIElement?) != nil { return true }
        let role: String? = attr(el, kAXRoleAttribute)
        return role == "AXTextArea" || role == "AXTextField"
    }

    /// Whether the element's frame overlaps the box (AppKit global coordinates).
    static func frameIntersects(_ el: AXUIElement, _ box: CGRect) -> Bool {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return true }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let topLeftBox = Geometry.topLeftGlobal(box, mainScreenHeight: mainHeight)
        return CGRect(origin: pos, size: size).intersects(topLeftBox)
    }

    /// Whether the element sits wholly inside the box (AppKit global coordinates).
    static func frameInside(_ el: AXUIElement, _ box: CGRect) -> Bool {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return false }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return Geometry.topLeftGlobal(box, mainScreenHeight: mainHeight).insetBy(dx: -8, dy: -8)
            .contains(CGRect(origin: pos, size: size))
    }

    /// "AXButton 'Save'" style line, or nil for anonymous containers.
    static func describe(_ el: AXUIElement) -> String? {
        let role: String = attr(el, kAXRoleAttribute) ?? "?"
        let label = [attr(el, kAXTitleAttribute) as String?,
                     attr(el, kAXDescriptionAttribute) as String?,
                     attr(el, kAXValueAttribute) as String?]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let label else { return nil }
        return "\(role) '\(String(label.prefix(120)))'"
    }

    /// Walk up to the enclosing web area and read its URL (Safari, Chrome, Arc, Electron apps).
    static func webURL(from el: AXUIElement) -> String? {
        var current: AXUIElement? = el
        for _ in 0..<40 {
            guard let node = current else { return nil }
            if (attr(node, kAXRoleAttribute) as String?) == "AXWebArea" {
                if let url: URL = attr(node, kAXURLAttribute) { return url.absoluteString }
                if let s: String = attr(node, kAXURLAttribute) { return s }
                return nil
            }
            current = attr(node, kAXParentAttribute)
        }
        return nil
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement) as? T
        }
        return value as? T
    }
}
