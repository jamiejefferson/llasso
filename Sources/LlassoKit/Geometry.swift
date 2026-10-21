import CoreGraphics

public enum Geometry {
    /// Convert a selection drawn in a screen-sized view (points, origin bottom-left)
    /// into a pixel rect in that screen's capture (origin top-left).
    public static func pixelCrop(selection: CGRect, screenSize: CGSize, imageSize: CGSize) -> CGRect {
        let sx = imageSize.width / screenSize.width
        let sy = imageSize.height / screenSize.height
        let r = CGRect(x: selection.minX * sx,
                       y: (screenSize.height - selection.maxY) * sy,
                       width: selection.width * sx,
                       height: selection.height * sy)
        return r.integral.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Convert a rect in AppKit global coordinates (origin bottom-left of the main
    /// display) into Quartz/Accessibility global coordinates (origin top-left).
    public static func topLeftGlobal(_ r: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: mainScreenHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Size that fits `size` inside `maxEdge` on its longest side, never upscaling.
    public static func fit(_ size: CGSize, maxEdge: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxEdge else { return size }
        let k = maxEdge / longest
        return CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
    }
}

public enum Sensitive {
    /// Apps Llasso refuses to capture. Matched as bundle-id prefixes.
    public static let bundlePrefixes = [
        "com.1password",
        "com.agilebits",
        "com.apple.keychainaccess",
        "com.apple.passwords",
        "com.lastpass",
        "com.bitwarden",
        "com.dashlane",
    ]

    public static func isSensitive(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return bundlePrefixes.contains { id.hasPrefix($0) }
    }
}
