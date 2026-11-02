import AppKit
import LlassoKit

/// Drives Photoshop through its own scripting (`do javascript`): reads the document and its
/// selection, exports the area an edit works on, adds a made picture back as a masked layer,
/// and runs Photoshop's own tools. Each change is one named step in Photoshop's History.
enum PhotoshopApp {
    static let bundleID = "com.adobe.Photoshop"

    /// Run ExtendScript in Photoshop; returns what its last statement evaluates to.
    static func run(_ js: String, timeout: TimeInterval) throws -> String {
        let quoted = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        with timeout of \(Int(timeout)) seconds
            tell application id "\(bundleID)" to do javascript "\(quoted)"
        end timeout
        """
        do {
            return try Shell.osascriptSync(script, timeout: timeout + 2)
        } catch {
            throw PhotoshopError(plain(error.localizedDescription))
        }
    }

    static func run(_ js: String, timeout: TimeInterval) async throws -> String {
        try await Task.detached { try run(js, timeout: timeout) }.value
    }

    /// osascript's error, minus the script position and app name, in the user's terms.
    static func plain(_ message: String) -> String {
        if message.contains("-1712") || message.contains("took too long") {
            return "Photoshop didn't answer. If a dialog is open in Photoshop, close it and try again."
        }
        if message.contains("-1743") || message.contains("Not authorized") {
            return "Llasso isn't allowed to control Photoshop. Turn it on in System Settings › Privacy & Security › Automation."
        }
        var m = message.replacingOccurrences(of: "The script failed: ", with: "")
        if let r = m.range(of: "got an error: ") { m = String(m[r.upperBound...]) }
        m = m.replacingOccurrences(of: "General Photoshop error occurred. This functionality may not be available in this version of Photoshop.", with: "")
        m = m.replacingOccurrences(of: #"\s*\(-?\d+\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-")))
        return m.isEmpty ? "Photoshop refused the step." : "Photoshop: " + m
    }

    /// The front document and its selection. `box` is in AppKit global coordinates. Nil when
    /// Photoshop has no document open or doesn't answer within a few seconds.
    static func read(box: CGRect?) -> PhotoshopState? {
        do {
            let out = try run(PhotoshopScript.read, timeout: 3)
            guard out != "none" else { return nil }
            let state = PhotoshopState.parse(out, box: box.map(topLeft))
            if let e = out.components(separatedBy: "\n").first(where: { $0.hasPrefix("viewError=") }) { Log.write("photoshop: no view (\(e.dropFirst(10)))") }
            return state
        } catch {
            Log.write("photoshop: read failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func topLeft(_ r: CGRect) -> CGRect {
        Geometry.topLeftGlobal(r, mainScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    /// The region of the document, all layers merged, as a PNG for the image model.
    static func export(_ s: PhotoshopState, maxEdge: Int = 2048) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Llasso Photoshop \(UUID().uuidString.prefix(8)).png")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await run(PhotoshopScript.export(document: s.documentID, region: s.region, maxEdge: maxEdge, to: url.path), timeout: 90)
        guard let png = try? Data(contentsOf: url) else { throw PhotoshopError("Photoshop didn't save the area for the image model.") }
        return png
    }

    /// Add `png` as a new layer over the region, masked to the selection when the user still has
    /// the same one. Returns the new layer's id.
    static func place(_ png: Data, state s: PhotoshopState, name: String) async throws -> Int {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Llasso layer \(UUID().uuidString.prefix(8)).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        // The mask is the live selection, so it only applies while that is still the one the
        // picture was made for.
        let now = await Task.detached { read(box: nil) }.value
        let mask: Bool
        if let was = s.selection, let sel = now?.selection, now?.documentID == s.documentID {
            mask = abs(sel.minX - was.minX) + abs(sel.minY - was.minY) + abs(sel.maxX - was.maxX) + abs(sel.maxY - was.maxY) <= 4
        } else { mask = false }
        let region = s.region
        let feather = mask ? max(1, (min(region.width, region.height) * 0.004).rounded()) : 0
        let out = try await run(PhotoshopScript.place(document: s.documentID, path: url.path, region: region,
                                                      name: name, mask: mask, feather: feather), timeout: 90)
        guard let id = out.components(separatedBy: "layer=").last.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
            throw PhotoshopError("Photoshop didn't say which layer it added.")
        }
        Log.write("photoshop: placed layer \(id) at \(region) mask \(mask)")
        return id
    }

    static func remove(layer: Int, document: Int, name: String) async throws {
        _ = try await run(PhotoshopScript.deleteLayer(document: document, layer: layer, name: name), timeout: 30)
    }

    /// Run one of Photoshop's own tools and return the document as it now stands.
    static func tool(_ t: PhotoshopTool, args: [String: Any], state s: PhotoshopState, box: CGRect?) async throws -> PhotoshopState? {
        let name = layerName(args["summary"] as? String ?? t.rawValue)
        let js = try PhotoshopScript.tool(t, args: args, document: s.documentID, box: s.boxed, name: name)
        let out = try await run(js, timeout: 120)
        return PhotoshopState.parse(out, box: box.map(topLeft))
    }

    /// "Llasso: <what>", short enough for the Layers and History panels.
    static func layerName(_ summary: String) -> String {
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Llasso: " + (s.count > 48 ? String(s.prefix(47)) + "…" : s.ifEmpty("edit"))
    }
}
