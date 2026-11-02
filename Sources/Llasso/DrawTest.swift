import AppKit

extension SelfTest {
    /// Three ways in, each with a real drag: "Draw a box" from the request list, ⌃⌥S, and
    /// ⌘-drag on the page. Each should open the prompt. A ⌘-click that doesn't move should
    /// leave Llasso idle. Then the keys change to ⌥⇧: an ⌥⇧-drag should open the prompt and a
    /// ⌘-drag should reach the app. Writes drawtest.json.
    @MainActor static func draw() async {
        var r: [String: Any] = [:]
        guard let delegate = NSApp.delegate as? AppDelegate, let screen = NSScreen.main else { return }
        // Quartz coordinates: origin top-left of the main display.
        let h = screen.frame.height
        let a = CGPoint(x: 300, y: h / 2), b = CGPoint(x: 600, y: h / 2 + 200)
        // Presses that reach "the app" land on this window of Llasso's own, so the test never
        // clicks or drags whatever else is on screen.
        let pad = NSWindow(contentRect: CGRect(x: a.x - 50, y: h - b.y - 50, width: b.x - a.x + 100, height: b.y - a.y + 100),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        pad.isReleasedWhenClosed = false
        pad.level = .floating
        pad.backgroundColor = .windowBackgroundColor
        pad.orderFrontRegardless()
        defer { pad.close() }
        var reached = 0, dragged = 0
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { e in
            if e.window === pad { if e.type == .leftMouseDragged { dragged += 1 } else if e.modifierFlags.contains(.command) { reached += 1 } }
            return e
        }
        defer { monitor.map(NSEvent.removeMonitor) }
        func post(_ t: CGEventType, _ p: CGPoint, flags: CGEventFlags = []) {
            let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        func drag(_ flags: CGEventFlags = []) async {
            post(.mouseMoved, a)
            try? await Task.sleep(nanoseconds: 100_000_000)
            post(.leftMouseDown, a, flags: flags)
            for i in 1...10 {
                try? await Task.sleep(nanoseconds: 30_000_000)
                post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 10, y: a.y + (b.y - a.y) * CGFloat(i) / 10),
                     flags: flags)
            }
            post(.leftMouseUp, b, flags: flags)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        func settle() async {
            Controller.shared.cancel()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        delegate.toggleTasks()
        try? await Task.sleep(nanoseconds: 800_000_000)
        delegate.drawFromList()
        try? await Task.sleep(nanoseconds: 600_000_000)
        await drag()
        r["menu"] = "\(Controller.shared.phase)"
        await settle()

        Controller.shared.toggle()
        try? await Task.sleep(nanoseconds: 600_000_000)
        await drag()
        r["hotkey"] = "\(Controller.shared.phase)"
        await settle()

        let chosen = Settings.shared.dragKeys
        Settings.shared.dragKeys = .standard
        await drag(.maskCommand)
        r["commandDrag"] = "\(Controller.shared.phase)"
        await settle()

        post(.leftMouseDown, a, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 80_000_000)
        post(.leftMouseUp, a, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 600_000_000)
        r["commandClick"] = "\(Controller.shared.phase)"
        r["commandClickReachedApp"] = reached
        await settle()

        // Keys changed in Settings: ⌥⇧ draws, and a ⌘-drag goes to the app.
        Settings.shared.dragKeys = [.option, .shift]
        await drag([.maskAlternate, .maskShift])
        r["optionShiftDrag"] = "\(Controller.shared.phase)"
        await settle()
        dragged = 0
        await drag(.maskCommand)
        r["commandDragAfterChange"] = "\(Controller.shared.phase)"
        r["commandDragAfterChangeReachedApp"] = dragged
        await drag([.maskAlternate, .maskShift, .maskCommand])
        r["extraKeyDrag"] = "\(Controller.shared.phase)"
        await settle()
        Settings.shared.dragKeys = chosen

        if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: History.folder.appendingPathComponent("drawtest.json"))
        }
    }
}
