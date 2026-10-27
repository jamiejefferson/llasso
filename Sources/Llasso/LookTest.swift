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
            job.card.route = RouteLine(work: "Image", model: "Claude Haiku 5.5", auto: true,
                                       reason: "Claude Haiku 5.5 handles design work as well as Claude Sonnet 5.5, and cheaper.")
            job.card.answer = "The sky in this photo runs from pale blue to peach. I can warm it towards amber and crop it square."
            job.card.state = .done
            try? await Task.sleep(nanoseconds: 700_000_000)
            await shoot(side, "look-\(name)-7-card")
            // A clip on the card, with the line that says which model made it.
            let clip = FileManager.default.temporaryDirectory.appendingPathComponent("llasso-check.mp4")
            if FileManager.default.fileExists(atPath: clip.path) {
                var p = ProposalCard(summary: "A paper boat drifting on the pond", destinations: [.saveAs, .copy])
                p.mediaURL = clip
                p.madeBy = "Made with Grok Imagine Video 1.5 Lite. Grok Imagine Video 1.5 Lite handles video as well as Seedance 2.0 Mini, and cheaper."
                job.card.answer = ""
                job.card.proposal = p
                job.show()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await shoot(CGRect(x: v.maxX - 640, y: v.maxY - 620, width: 640, height: 620), "look-\(name)-7b-clip")
            }
            // Text that can go back in place asks first.
            var t = ProposalCard(summary: "Translated into French", destinations: [.replaceInPlace(app: "Notes"), .copy, .newDocument, .saveAs])
            t.text = "Trois jours sur la Tay avec un carnet de croquis et un thermos."
            t.original = "Three days on the Tay with a sketchbook and a thermos."
            t.ask = "Replace the boxed text in Notes with this?"
            job.card.proposal = t
            job.show()
            try? await Task.sleep(nanoseconds: 900_000_000)
            await shoot(CGRect(x: v.maxX - 640, y: v.maxY - 560, width: 640, height: 560), "look-\(name)-7c-ask")
            // A request one result can't answer: the plan waits for a yes, then each result shows.
            job.card.proposal = nil
            job.card.title = "Illustrate this and add a spoken line, as one clip"
            job.card.route = RouteLine(work: "Image", model: "Seedream 5.0 Flash", auto: false, reason: "")
            job.card.plan = PlanCard(summary: "An illustration of the van with a spoken line, joined into one clip.", lines: [
                .init(id: "1", label: "Image", model: "Seedream 5.0 Flash", summary: "Flat illustration of the van"),
                .init(id: "2", label: "Speech", model: "Gemini 3.8 Flash TTS", summary: "A spoken line, under ten words"),
                .init(id: "3", label: "Combine", model: "On this Mac", summary: "Join the picture and the voice into one clip", uses: "uses 1 and 2"),
            ])
            job.show()
            try? await Task.sleep(nanoseconds: 900_000_000)
            await shoot(CGRect(x: v.maxX - 640, y: v.maxY - 560, width: 640, height: 560), "look-\(name)-7d-plan")
            job.card.plan?.approved = true
            job.card.plan?.lines[0].status = .done
            job.card.plan?.lines[1].status = .done
            job.card.plan?.lines[2].status = .working
            job.card.working = "Joining the parts on this Mac…"
            job.card.state = .thinking
            try? await Task.sleep(nanoseconds: 600_000_000)
            await shoot(CGRect(x: v.maxX - 640, y: v.maxY - 560, width: 640, height: 560), "look-\(name)-7e-plan-running")
            job.card.working = nil
            job.card.state = .done
            job.card.plan?.lines[2].status = .done
            var caption = ProposalCard(summary: "One-line caption", destinations: [.replaceInPlace(app: "Notes"), .copy, .newDocument, .saveAs])
            caption.text = "The little grey van that brought the whole street its post."
            caption.madeBy = "Made with Claude Haiku 5.5. Your choice for writing."
            caption.ask = "Replace the boxed text in Notes with this?"
            var made = ProposalCard(summary: "Join the picture and the voice into one clip", destinations: [.saveAs, .copy])
            made.mediaURL = FileManager.default.fileExists(atPath: clip.path) ? clip : nil
            made.madeBy = "Joined on this Mac from step 1 by Seedream 5.0 Flash and step 2 by Gemini 3.8 Flash TTS."
            job.card.results = [caption, made]
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await shoot(CGRect(x: v.maxX - 640, y: v.maxY - 1100, width: 640, height: 1100), "look-\(name)-7f-plan-results")
            job.close()
            backdrop.orderOut(nil)

            // Settings, first run, with a key saved, and after a paste OpenRouter refused: the key
            // field should read as a place to paste, and a refusal should say why.
            for (state, noKey, problem) in [("nokey", true, nil), ("saved", false, nil),
                                            ("refused", true, "That isn't an OpenRouter key. Keys start with sk-or-.")] {
                let w = NSWindow(contentRect: CGRect(x: v.midX - 270, y: v.maxY - 820, width: 540, height: 780),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.title = "Llasso Settings"
                w.isReleasedWhenClosed = false
                w.contentView = NSHostingView(rootView: SettingsView(showsNoKey: noKey, showsProblem: problem))
                w.orderFrontRegardless()
                try? await Task.sleep(nanoseconds: 600_000_000)
                await shoot(w.frame, "look-\(name)-8-settings-\(state)")
                if state == "saved" {
                    // Scrolled to the Models section.
                    if let scroll = Self.firstScrollView(in: w.contentView) {
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: 330))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        await shoot(w.frame, "look-\(name)-8b-settings-models")
                    }
                }
                w.orderOut(nil)
            }

            // The model picker, for a chat model and an image model.
            for _ in 0..<60 where ModelStore.shared.loading || ModelStore.shared.lists.isEmpty {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            for work in [Work.writing, .image] {
                ModelBrowserWindow.show(work)
                try? await Task.sleep(nanoseconds: 900_000_000)
                if let w = NSApp.windows.first(where: { $0.title == "Choose a model" && $0.isVisible }) {
                    await shoot(w.frame, "look-\(name)-9-picker-\(work.rawValue)")
                    w.close()
                }
            }
        }
        NSApp.appearance = nil
    }

    static func firstScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let s = view as? NSScrollView { return s }
        for sub in view.subviews { if let s = firstScrollView(in: sub) { return s } }
        return nil
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
