import AppKit
import ScreenCaptureKit
import SwiftUI
import LlassoKit

/// `--looktest`: puts the marquee mid-drag, the prompt and a card on screen over a light
/// and a dark backdrop, and saves what the screen shows to look-*.png in the history folder.
extension SelfTest {
    static func look() async {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let frame = CGRect(x: v.midX - 480, y: v.midY - 300, width: 960, height: 600)
        let box = CGRect(x: frame.minX + 520, y: frame.minY + 250, width: 300, height: 260)
        let release = CGPoint(x: box.maxX, y: box.minY)

        for dark in [false, true] {
            let name = dark ? "dark" : "light"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let backdrop = Backdrop.window(frame: frame, dark: dark)
            backdrop.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 300_000_000)

            // Mid ⌘-drag: the marquee follows the pointer.
            _ = Controller.shared.beginDrag(at: CGPoint(x: box.minX, y: box.maxY))
            Controller.shared.drag(to: CGPoint(x: box.midX + 60, y: box.midY - 40))
            try? await Task.sleep(nanoseconds: 300_000_000)
            await shoot(frame, "look-\(name)-1-drawing")
            Controller.shared.cancel()

            Controller.shared.begin(box: box)
            try? await Task.sleep(nanoseconds: 120_000_000)
            await shoot(frame, "look-\(name)-4-prompt-opening")
            try? await Task.sleep(nanoseconds: 800_000_000)
            await shoot(frame, "look-\(name)-5-prompt")
            Controller.shared.testListening(0.7)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await shoot(CGRect(x: box.minX - 40, y: box.minY - 330, width: 700, height: 320), "look-\(name)-5b-listening")
            Controller.shared.testListening(nil)
            Controller.shared.testType("Can you take the key facts from this page, the price, the battery size, the weight and the charging time, and write them as a short list I can paste into my notes, then suggest two cheaper alternatives with the same output and say where to buy them in the UK, and finally tell me whether it will work with a trickle charger on a classic car battery over a long winter.")
            try? await Task.sleep(nanoseconds: 500_000_000)
            await shoot(CGRect(x: box.minX - 40, y: box.minY - 480, width: 700, height: 470), "look-\(name)-5c-long")
            Controller.shared.cancel()
            try? await Task.sleep(nanoseconds: 400_000_000)

            // Sent: the box and prompt go, a Working chip waits at the right edge.
            let job = Controller.shared.showTestCard(box: (box, screen))
            job.card.title = "Warm the sky up"
            job.card.working = "Editing the image…"
            try? await Task.sleep(nanoseconds: 700_000_000)
            let side = CGRect(x: v.maxX - 640, y: v.maxY - 420, width: 640, height: 420)
            await shoot(side, "look-\(name)-6-working")
            // The answer arrives: the card comes up at the side by itself.
            job.card.working = nil
            job.card.answer = "The sky in this photo runs from pale blue to peach. I can warm it towards amber and crop it square."
            job.card.state = .done
            try? await Task.sleep(nanoseconds: 700_000_000)
            await shoot(side, "look-\(name)-7-card")
            job.close()
            backdrop.orderOut(nil)

            // Settings, first run, with a key saved, and after a paste OpenRouter refused: the key
            // field should read as a place to paste, and a refusal should say why.
            for (state, noKey, problem) in [("nokey", true, nil), ("saved", false, nil),
                                            ("refused", true, "That isn't an OpenRouter key. Keys start with sk-or-.")] {
                let w = NSWindow(contentRect: CGRect(x: v.midX - 260, y: v.maxY - 760, width: 520, height: 720),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.title = "Llasso Settings"
                w.isReleasedWhenClosed = false
                w.contentView = NSHostingView(rootView: SettingsView(showsNoKey: noKey, showsProblem: problem))
                w.orderFrontRegardless()
                try? await Task.sleep(nanoseconds: 600_000_000)
                await shoot(w.frame, "look-\(name)-8-settings-\(state)")
                w.orderOut(nil)
            }
        }
        NSApp.appearance = nil
    }

    private static func shoot(_ rect: CGRect, _ name: String) async {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == CGDirectDisplayID(number.uint32Value) })
        else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        cfg.width = Int(CGFloat(display.width) * scale)
        cfg.height = Int(CGFloat(display.height) * scale)
        cfg.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return }
        let local = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let crop = CGRect(x: local.minX * scale, y: (screen.frame.height - local.maxY) * scale,
                          width: local.width * scale, height: local.height * scale)
        guard let cut = image.cropping(to: crop), let png = try? Capture.png(cut) else { return }
        try? png.write(to: History.folder.appendingPathComponent(name + ".png"))
    }
}

/// A stand-in app window: a journal page in light mode, poster drafts in dark mode.
private enum Backdrop {
    @MainActor
    static func window(frame: CGRect, dark: Bool) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .normal
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: Page(dark: dark).frame(width: frame.width, height: frame.height))
        return w
    }

    struct Page: View {
        var dark: Bool
        var body: some View {
            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(dark ? "POSTER DRAFTS" : "FIELD NOTES").font(.system(size: 12, weight: .semibold)).tracking(1.5)
                        .foregroundColor(.gray)
                    Text(dark ? "Night market, three ways" : "Morning light over the estuary")
                        .font(.system(size: 40, weight: .heavy)).foregroundColor(dark ? .white : .black)
                    Text("Three days on the Tay with a sketchbook and a thermos.")
                        .font(.system(size: 17)).foregroundColor(dark ? Color(white: 0.7) : Color(white: 0.35))
                }
                .frame(width: 380, alignment: .leading)
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: dark
                        ? [Color(red: 0.11, green: 0.17, blue: 0.29), Color(red: 0.23, green: 0.16, blue: 0.42), Color(red: 0.76, green: 0.28, blue: 0.48), Color(red: 0.95, green: 0.65, blue: 0.35)]
                        : [Color(red: 0.62, green: 0.76, blue: 0.88), Color(red: 0.96, green: 0.79, blue: 0.65), Color(red: 0.9, green: 0.6, blue: 0.43), Color(red: 0.24, green: 0.33, blue: 0.4)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 280, height: 240)
            }
            .padding(60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(dark ? Color(red: 0.055, green: 0.06, blue: 0.067) : Color.white)
        }
    }
}
