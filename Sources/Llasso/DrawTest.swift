import AppKit

extension SelfTest {
    /// Three ways in, each with a real drag: "Draw a box" from the request list, ⌃⌥S, and
    /// ⌘-drag on the page. Each should open the prompt. A ⌘-click that doesn't move should
    /// leave Llasso idle. Writes drawtest.json.
    @MainActor static func draw() async {
        var r: [String: Any] = [:]
        guard let delegate = NSApp.delegate as? AppDelegate, let screen = NSScreen.main else { return }
        // Quartz coordinates: origin top-left of the main display.
        let h = screen.frame.height
        let a = CGPoint(x: 300, y: h / 2), b = CGPoint(x: 600, y: h / 2 + 200)
        func post(_ t: CGEventType, _ p: CGPoint, command: Bool = false) {
            let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)
            if command { e?.flags = .maskCommand }
            e?.post(tap: .cghidEventTap)
        }
        func drag(command: Bool) async {
            post(.mouseMoved, a)
            try? await Task.sleep(nanoseconds: 100_000_000)
            post(.leftMouseDown, a, command: command)
            for i in 1...10 {
                try? await Task.sleep(nanoseconds: 30_000_000)
                post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 10, y: a.y + (b.y - a.y) * CGFloat(i) / 10),
                     command: command)
            }
            post(.leftMouseUp, b, command: command)
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
        await drag(command: false)
        r["menu"] = "\(Controller.shared.phase)"
        await settle()

        Controller.shared.toggle()
        try? await Task.sleep(nanoseconds: 600_000_000)
        await drag(command: false)
        r["hotkey"] = "\(Controller.shared.phase)"
        await settle()

        await drag(command: true)
        r["commandDrag"] = "\(Controller.shared.phase)"
        await settle()

        // A global monitor only sees clicks that reach another app.
        var reached = 0
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
            if e.modifierFlags.contains(.command) { reached += 1 }
        }
        post(.leftMouseDown, a, command: true)
        try? await Task.sleep(nanoseconds: 80_000_000)
        post(.leftMouseUp, a, command: true)
        try? await Task.sleep(nanoseconds: 600_000_000)
        monitor.map(NSEvent.removeMonitor)
        r["commandClick"] = "\(Controller.shared.phase)"
        r["commandClickReachedApp"] = reached
        await settle()

        if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: History.folder.appendingPathComponent("drawtest.json"))
        }
    }
}
