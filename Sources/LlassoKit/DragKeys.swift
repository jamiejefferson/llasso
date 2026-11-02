import CoreGraphics

/// The keys held while dragging to draw a box: ⌘ unless changed in Settings.
public struct DragKeys: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = DragKeys(rawValue: 1)
    public static let option = DragKeys(rawValue: 2)
    public static let shift = DragKeys(rawValue: 4)
    public static let command = DragKeys(rawValue: 8)
    public static let standard: DragKeys = .command

    /// In the order macOS writes them: ⌃⌥⇧⌘.
    public static let each: [(key: DragKeys, symbol: String, name: String)] = [
        (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"), (.command, "⌘", "Command"),
    ]

    /// ⇧ on its own would take every shift-drag that extends a text selection.
    public var isUsable: Bool { !intersection([.control, .option, .command]).isEmpty }

    public var symbols: String { Self.each.filter { contains($0.key) }.map(\.symbol).joined() }

    /// The keys a mouse event says are held.
    public init(flags: CGEventFlags) {
        var k = DragKeys()
        if flags.contains(.maskControl) { k.insert(.control) }
        if flags.contains(.maskAlternate) { k.insert(.option) }
        if flags.contains(.maskShift) { k.insert(.shift) }
        if flags.contains(.maskCommand) { k.insert(.command) }
        self = k
    }

    /// Exactly these keys are held, so a drag with one more key held still goes to the app.
    public func matches(_ flags: CGEventFlags) -> Bool { DragKeys(flags: flags) == self }
}
