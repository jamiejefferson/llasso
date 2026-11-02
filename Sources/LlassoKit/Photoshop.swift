import Foundation
import CoreGraphics

/// The open Photoshop document and what is selected in it, read through Photoshop's own
/// scripting. Rectangles are in document pixels with the origin at the top left.
public struct PhotoshopState: Sendable, Equatable {
    public var documentID: Int
    public var document: String
    public var size: CGSize
    public var layer: String
    /// Bounds of the user's own selection; nil when nothing is selected.
    public var selection: CGRect?
    /// Where the document sits on screen, in top-left global points, when Photoshop said.
    public var view: CGRect?
    /// The box, in document pixels, when the view was known.
    public var boxed: CGRect?

    public init(documentID: Int, document: String, size: CGSize, layer: String,
                selection: CGRect? = nil, view: CGRect? = nil, boxed: CGRect? = nil) {
        self.documentID = documentID
        self.document = document
        self.size = size
        self.layer = layer
        self.selection = selection
        self.view = view
        self.boxed = boxed
    }

    public var bounds: CGRect { CGRect(origin: .zero, size: size) }

    /// The area an edit works on: the user's selection, else the box, else the whole picture.
    public var region: CGRect { selection ?? boxed ?? bounds }

    public var regionSource: String {
        selection != nil ? "the selection" : boxed != nil ? "the boxed area" : "the whole picture"
    }

    /// Read the lines the read script prints ("key=value"), mapping `box` (top-left global
    /// points) into the document when the view came back.
    public static func parse(_ out: String, box: CGRect? = nil) -> PhotoshopState? {
        var v: [String: String] = [:]
        for line in out.components(separatedBy: .newlines) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            v[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let id = v["id"].flatMap(Int.init), let w = v["w"].flatMap(Double.init),
              let h = v["h"].flatMap(Double.init), w > 0, h > 0 else { return nil }
        var s = PhotoshopState(documentID: id, document: v["name"] ?? "Untitled", size: CGSize(width: w, height: h),
                               layer: v["layer"] ?? "")
        s.selection = v["sel"].flatMap(rect)
        s.view = v["view"].flatMap(rect)
        if let box, let view = s.view { s.boxed = map(box, view: view, size: s.size) }
        return s
    }

    /// "left,top,right,bottom" to a rect; nil when empty or malformed.
    static func rect(_ s: String) -> CGRect? {
        let n = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 4, n[2] > n[0], n[3] > n[1] else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
    }

    /// The box in document pixels, clipped to the picture; nil when it misses the picture.
    public static func map(_ box: CGRect, view: CGRect, size: CGSize) -> CGRect? {
        guard view.width > 0, view.height > 0 else { return nil }
        let kx = size.width / view.width, ky = size.height / view.height
        let r = CGRect(x: (box.minX - view.minX) * kx, y: (box.minY - view.minY) * ky,
                       width: box.width * kx, height: box.height * ky).integral
            .intersection(CGRect(origin: .zero, size: size))
        return r.isNull || r.width < 2 || r.height < 2 ? nil : r
    }
}

/// Photoshop's own tools, offered to the model when the box is over a Photoshop document.
/// Each runs as one named step in Photoshop's History, so ⌘Z there takes it back.
public enum PhotoshopTool: String, CaseIterable, Sendable {
    case select = "photoshop_select"
    case adjust = "photoshop_adjust"
    case retouch = "photoshop_retouch"

    public static let selections = ["subject", "sky", "box", "invert", "all", "none"]
    public static let adjustments = ["brightness_contrast", "hue_saturation", "vibrance", "exposure",
                                     "black_and_white", "photo_filter", "invert"]
    public static let retouches = ["remove_background", "content_aware_fill", "blur", "sharpen"]

    public var schema: [String: Any] {
        func fn(_ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            var p = properties
            p["summary"] = ["type": "string", "description": "A few words for Photoshop's History and the card, such as \"Warmer sky\"."]
            return ["type": "function",
                    "function": ["name": rawValue, "description": description,
                                 "parameters": ["type": "object", "properties": p, "required": required + ["summary"]]]]
        }
        func number(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
        switch self {
        case .select:
            return fn("Change the selection in Photoshop. subject and sky use Photoshop's own detection; box selects the boxed area; invert flips the selection; all and none select everything or nothing. Returns the new selection.",
                      ["what": ["type": "string", "enum": Self.selections]], ["what"])
        case .adjust:
            return fn("Add an adjustment layer in Photoshop. It changes only the selected area when there is a selection, and the user can retune it in Photoshop's Properties panel. Give only the values that matter; the rest stay neutral.",
                      ["kind": ["type": "string", "enum": Self.adjustments],
                       "brightness": number("brightness_contrast: -150 to 150"),
                       "contrast": number("brightness_contrast: -50 to 100"),
                       "hue": number("hue_saturation: -180 to 180"),
                       "saturation": number("hue_saturation or vibrance: -100 to 100"),
                       "lightness": number("hue_saturation: -100 to 100"),
                       "vibrance": number("vibrance: -100 to 100"),
                       "exposure": number("exposure: -5 to 5 stops"),
                       "colour": ["type": "string", "description": "photo_filter: hex colour such as #EC8A00 for warm or #006DFF for cool"],
                       "density": number("photo_filter: 0 to 100")],
                      ["kind"])
        case .retouch:
            return fn("Change pixels on the active layer with Photoshop's own tools. remove_background masks out everything but the subject. content_aware_fill fills the selection from its surroundings, which removes what is selected. blur (amount: radius in pixels) and sharpen (amount: percent) work on the selected area.",
                      ["action": ["type": "string", "enum": Self.retouches],
                       "amount": number("blur radius in pixels, or sharpen amount in percent")],
                      ["action"])
        }
    }

    /// Added to the system prompt when a Photoshop document is under the box.
    public static let guide = """
    Photoshop: the context names the open document and its selection. Llasso drives Photoshop directly, \
    and every change lands as one named step in Photoshop's History, so the user can undo it there.
    - Tone and colour (brighter, warmer, less saturated, black and white): call photoshop_adjust. It adds an \
    adjustment layer limited to the selection.
    - Removing something: select it if it is not selected, then photoshop_retouch content_aware_fill.
    - Cut-outs: photoshop_retouch remove_background, or photoshop_select subject to select the subject.
    - Adding, replacing or restyling content in an area: call edit_image. It sends that area of the document \
    at full resolution to the image model and the user adds the result as a new layer masked to the selection. \
    Write the instruction as an edit of the picture it receives: say what changes, and to keep everything \
    else (framing, perspective, light, grain) as it is.
    - When the request names something that is not selected (the sky, the person), select it first with \
    photoshop_select, then act.
    - Photoshop's tools run without asking. After they run, say in one sentence what changed.
    """

    public static func named(_ name: String) -> PhotoshopTool? { PhotoshopTool(rawValue: name) }
}

/// The ExtendScript Llasso sends to Photoshop with `do javascript`. Photoshop's engine is
/// ES3: no let, no arrow functions and no JSON object.
public enum PhotoshopScript {
    /// A JavaScript string literal.
    public static func literal(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]) else { return "\"\"" }
        return String(decoding: d, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Helpers every script starts with. `llDoc` makes the document with that id active.
    public static let prelude = """
    function llPx(v) { return Math.round(v.as("px")); }
    function llClean(s) { return String(s).replace(/[\\r\\n]+/g, " "); }
    function llDoc(id) {
        for (var i = 0; i < app.documents.length; i++) {
            if (app.documents[i].id == id) { if (app.activeDocument != app.documents[i]) app.activeDocument = app.documents[i]; return app.documents[i]; }
        }
        throw new Error("The Photoshop document has closed.");
    }
    function llState(d) {
        var units = app.preferences.rulerUnits;
        app.preferences.rulerUnits = Units.PIXELS;
        try {
            var s = "id=" + d.id + "\\nname=" + llClean(d.name) + "\\nw=" + llPx(d.width) + "\\nh=" + llPx(d.height);
            try { s += "\\nlayer=" + llClean(d.activeLayer.name); } catch (e) {}
            try { var b = d.selection.bounds; s += "\\nsel=" + llPx(b[0]) + "," + llPx(b[1]) + "," + llPx(b[2]) + "," + llPx(b[3]); } catch (e) {}
            try { s += "\\nview=" + llView(d); } catch (e) { s += "\\nviewError=" + llClean(e.message); }
            return s;
        } finally { app.preferences.rulerUnits = units; }
    }
    function llView(d) {
        var r = new ActionReference();
        r.putProperty(charIDToTypeID("Prpr"), stringIDToTypeID("viewInfo"));
        r.putIdentifier(charIDToTypeID("Dcmn"), d.id);
        var v = executeActionGet(r).getObjectValue(stringIDToTypeID("viewInfo")).getObjectValue(stringIDToTypeID("activeView"));
        var g = v.getObjectValue(stringIDToTypeID("globalBounds"));
        var c = v.getObjectValue(stringIDToTypeID("center"));
        var r2 = new ActionReference();
        r2.putProperty(charIDToTypeID("Prpr"), stringIDToTypeID("zoom"));
        r2.putIdentifier(charIDToTypeID("Dcmn"), d.id);
        var z = executeActionGet(r2).getUnitDoubleValue(stringIDToTypeID("zoom"));
        var cx = (g.getDouble(stringIDToTypeID("left")) + g.getDouble(stringIDToTypeID("right"))) / 2;
        var cy = (g.getDouble(stringIDToTypeID("top")) + g.getDouble(stringIDToTypeID("bottom"))) / 2;
        var w = llPx(d.width) * z, h = llPx(d.height) * z;
        var left = cx - c.getDouble(stringIDToTypeID("horizontal")) * z, top = cy - c.getDouble(stringIDToTypeID("vertical")) * z;
        return left + "," + top + "," + (left + w) + "," + (top + h);
    }
    function llPixels(d, smart) {
        var a = d.activeLayer;
        if (a.typename == "ArtLayer" && (a.kind == LayerKind.NORMAL || (smart && a.kind == LayerKind.SMARTOBJECT))) return a;
        for (var i = 0; i < d.artLayers.length; i++) {
            var l = d.artLayers[i];
            if (l.visible && l.kind == LayerKind.NORMAL) { d.activeLayer = l; return l; }
        }
        throw new Error("There is no pixel layer to change. Pick one in the Layers panel.");
    }
    function llRun(name, body) {
        var d = app.activeDocument;
        var units = app.preferences.rulerUnits, dialogs = app.displayDialogs;
        app.preferences.rulerUnits = Units.PIXELS;
        app.displayDialogs = DialogModes.NO;
        llBody = body;
        llOut = "";
        try { d.suspendHistory(name, "llOut = llBody(app.activeDocument) || ''"); }
        finally { app.preferences.rulerUnits = units; app.displayDialogs = dialogs; }
        return llOut;
    }
    var llBody, llOut;

    """

    /// The document, its size, active layer, selection and on-screen view.
    public static let read = prelude + """
    app.documents.length == 0 ? "none" : llState(app.activeDocument);
    """

    /// Save `region` of the document, all layers merged, as an RGB PNG no longer than `maxEdge`.
    public static func export(document id: Int, region r: CGRect, maxEdge: Int, to path: String) -> String {
        prelude + """
        (function () {
            var d = llDoc(\(id));
            var units = app.preferences.rulerUnits, dialogs = app.displayDialogs;
            app.preferences.rulerUnits = Units.PIXELS;
            app.displayDialogs = DialogModes.NO;
            try {
                var c = d.duplicate("Llasso export", true);
                c.crop([UnitValue(\(Int(r.minX)), "px"), UnitValue(\(Int(r.minY)), "px"), UnitValue(\(Int(r.maxX)), "px"), UnitValue(\(Int(r.maxY)), "px")]);
                if (c.mode != DocumentMode.RGB) c.changeMode(ChangeMode.RGB);
                if (c.bitsPerChannel != BitsPerChannelType.EIGHT) c.bitsPerChannel = BitsPerChannelType.EIGHT;
                var w = llPx(c.width), h = llPx(c.height), k = Math.min(1, \(maxEdge) / Math.max(w, h));
                if (k < 1) c.resizeImage(UnitValue(Math.round(w * k), "px"), UnitValue(Math.round(h * k), "px"), undefined, ResampleMethod.BICUBIC);
                c.saveAs(new File(\(literal(path))), new PNGSaveOptions(), true, Extension.LOWERCASE);
                c.close(SaveOptions.DONOTSAVECHANGES);
                app.activeDocument = d;
                return "ok";
            } finally { app.preferences.rulerUnits = units; app.displayDialogs = dialogs; }
        })();
        """
    }

    /// Place the PNG at `path` as a new layer filling `region`, masked to the selection when
    /// `mask` is set, as one History step. Prints the new layer's id.
    public static func place(document id: Int, path: String, region r: CGRect, name: String, mask: Bool, feather: Double) -> String {
        prelude + """
        llDoc(\(id));
        llRun(\(literal(name)), function (d) {
            var ch = null;
            if (\(mask)) { try { d.selection.bounds; ch = d.channels.add(); d.selection.store(ch); } catch (e) { ch = null; } }
            d.selection.deselect();
            var p = new ActionDescriptor();
            p.putPath(charIDToTypeID("null"), new File(\(literal(path))));
            p.putEnumerated(charIDToTypeID("FTcs"), charIDToTypeID("QCSt"), charIDToTypeID("Qcsa"));
            executeAction(charIDToTypeID("Plc "), p, DialogModes.NO);
            var L = d.activeLayer, b = L.bounds;
            L.resize(\(Int(r.width)) / (llPx(b[2]) - llPx(b[0])) * 100, \(Int(r.height)) / (llPx(b[3]) - llPx(b[1])) * 100, AnchorPosition.TOPLEFT);
            b = L.bounds;
            L.translate(UnitValue(\(Int(r.minX)) - llPx(b[0]), "px"), UnitValue(\(Int(r.minY)) - llPx(b[1]), "px"));
            L.name = \(literal(name));
            if (ch) {
                d.selection.load(ch);
                var m = new ActionDescriptor(), at = new ActionReference();
                m.putClass(charIDToTypeID("Nw  "), charIDToTypeID("Chnl"));
                at.putEnumerated(charIDToTypeID("Chnl"), charIDToTypeID("Chnl"), charIDToTypeID("Msk "));
                m.putReference(charIDToTypeID("At  "), at);
                m.putEnumerated(charIDToTypeID("Usng"), charIDToTypeID("UsrM"), charIDToTypeID("RvlS"));
                executeAction(charIDToTypeID("Mk  "), m, DialogModes.NO);
                if (\(feather) > 0) {
                    var t = new ActionReference(), s = new ActionDescriptor(), f = new ActionDescriptor();
                    t.putEnumerated(charIDToTypeID("Lyr "), charIDToTypeID("Ordn"), charIDToTypeID("Trgt"));
                    s.putReference(charIDToTypeID("null"), t);
                    f.putUnitDouble(stringIDToTypeID("userMaskFeather"), charIDToTypeID("#Pxl"), \(feather));
                    s.putObject(charIDToTypeID("T   "), charIDToTypeID("Lyr "), f);
                    executeAction(charIDToTypeID("setd"), s, DialogModes.NO);
                }
                ch.remove();
            }
            return "layer=" + L.id;
        });
        """
    }

    /// Delete the layer Llasso added, as one History step.
    public static func deleteLayer(document id: Int, layer: Int, name: String) -> String {
        prelude + """
        llDoc(\(id));
        llRun(\(literal(name)), function (d) {
            var r = new ActionReference(), x = new ActionDescriptor();
            r.putIdentifier(charIDToTypeID("Lyr "), \(layer));
            x.putReference(charIDToTypeID("null"), r);
            executeAction(charIDToTypeID("Dlt "), x, DialogModes.NO);
            return "deleted";
        });
        """
    }

    /// One of Photoshop's own tools, as one History step named `name`. Prints the new state.
    /// `box` is the boxed area in document pixels, for selecting it.
    public static func tool(_ t: PhotoshopTool, args a: [String: Any], document id: Int, box: CGRect?, name: String) throws -> String {
        func num(_ k: String, _ fallback: Double = 0) -> Double {
            (a[k] as? Double) ?? (a[k] as? Int).map(Double.init) ?? (a[k] as? String).flatMap(Double.init) ?? fallback
        }
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
        let body: String
        switch t {
        case .select:
            switch a["what"] as? String ?? "" {
            case "subject":
                body = """
                var x = new ActionDescriptor(); x.putBoolean(stringIDToTypeID("sampleAllLayers"), true);
                executeAction(stringIDToTypeID("autoCutout"), x, DialogModes.NO);
                """
            case "sky": body = "executeAction(stringIDToTypeID(\"selectSky\"), new ActionDescriptor(), DialogModes.NO);"
            case "invert": body = "d.selection.invert();"
            case "all": body = "d.selection.selectAll();"
            case "none": body = "d.selection.deselect();"
            case "box":
                guard let r = box else { throw PhotoshopError("Llasso couldn't tell where the box sits in the picture, so it can't select it.") }
                body = "d.selection.select([[\(Int(r.minX)), \(Int(r.minY))], [\(Int(r.maxX)), \(Int(r.minY))], [\(Int(r.maxX)), \(Int(r.maxY))], [\(Int(r.minX)), \(Int(r.maxY))]]);"
            case let w: throw PhotoshopError("Photoshop can't select \(w.isEmpty ? "that" : w).")
            }
        case .adjust:
            let make: String
            switch a["kind"] as? String ?? "" {
            case "brightness_contrast":
                make = """
                t.putInteger(stringIDToTypeID("brightness"), \(Int(clamp(num("brightness"), -150, 150))));
                t.putInteger(stringIDToTypeID("center"), \(Int(clamp(num("contrast"), -50, 100))));
                t.putBoolean(stringIDToTypeID("useLegacy"), false);
                u.putObject(charIDToTypeID("Type"), stringIDToTypeID("brightnessEvent"), t);
                """
            case "hue_saturation":
                make = """
                var l = new ActionList(), m = new ActionDescriptor();
                t.putEnumerated(stringIDToTypeID("presetKind"), stringIDToTypeID("presetKindType"), stringIDToTypeID("presetKindCustom"));
                t.putBoolean(stringIDToTypeID("colorize"), false);
                m.putInteger(stringIDToTypeID("hue"), \(Int(clamp(num("hue"), -180, 180))));
                m.putInteger(stringIDToTypeID("saturation"), \(Int(clamp(num("saturation"), -100, 100))));
                m.putInteger(stringIDToTypeID("lightness"), \(Int(clamp(num("lightness"), -100, 100))));
                l.putObject(stringIDToTypeID("hueSatAdjustmentV2"), m);
                t.putList(stringIDToTypeID("adjustment"), l);
                u.putObject(charIDToTypeID("Type"), stringIDToTypeID("hueSaturation"), t);
                """
            case "vibrance":
                make = """
                t.putInteger(stringIDToTypeID("vibrance"), \(Int(clamp(num("vibrance"), -100, 100))));
                t.putInteger(stringIDToTypeID("saturation"), \(Int(clamp(num("saturation"), -100, 100))));
                u.putObject(charIDToTypeID("Type"), stringIDToTypeID("vibrance"), t);
                """
            case "exposure":
                make = """
                t.putEnumerated(stringIDToTypeID("presetKind"), stringIDToTypeID("presetKindType"), stringIDToTypeID("presetKindCustom"));
                t.putDouble(stringIDToTypeID("exposure"), \(clamp(num("exposure"), -5, 5)));
                t.putDouble(stringIDToTypeID("offset"), 0);
                t.putDouble(stringIDToTypeID("gammaCorrection"), 1);
                u.putObject(charIDToTypeID("Type"), stringIDToTypeID("exposure"), t);
                """
            case "black_and_white":
                make = "u.putObject(charIDToTypeID(\"Type\"), stringIDToTypeID(\"blackAndWhite\"), t);"
            case "invert":
                make = "u.putClass(charIDToTypeID(\"Type\"), charIDToTypeID(\"Invr\"));"
            case "photo_filter":
                let hex = (a["colour"] as? String ?? a["color"] as? String ?? "#EC8A00").trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                let v = Int(hex, radix: 16) ?? 0xEC8A00
                make = """
                var c = new ActionDescriptor();
                c.putDouble(charIDToTypeID("Rd  "), \((v >> 16) & 0xFF));
                c.putDouble(charIDToTypeID("Grn "), \((v >> 8) & 0xFF));
                c.putDouble(charIDToTypeID("Bl  "), \(v & 0xFF));
                t.putObject(charIDToTypeID("Clr "), charIDToTypeID("RGBC"), c);
                t.putInteger(charIDToTypeID("Dnst"), \(Int(clamp(num("density", 25), 0, 100))));
                t.putBoolean(charIDToTypeID("PrsL"), true);
                u.putObject(charIDToTypeID("Type"), stringIDToTypeID("photoFilter"), t);
                """
            case let k: throw PhotoshopError("Photoshop has no \(k.isEmpty ? "such" : k) adjustment here.")
            }
            body = """
            var x = new ActionDescriptor(), r = new ActionReference(), u = new ActionDescriptor(), t = new ActionDescriptor();
            r.putClass(charIDToTypeID("AdjL"));
            x.putReference(charIDToTypeID("null"), r);
            \(make)
            x.putObject(charIDToTypeID("Usng"), charIDToTypeID("AdjL"), u);
            executeAction(charIDToTypeID("Mk  "), x, DialogModes.NO);
            d.activeLayer.name = \(literal(name));
            """
        case .retouch:
            switch a["action"] as? String ?? "" {
            case "remove_background":
                body = "llPixels(d, true); executeAction(stringIDToTypeID(\"removeBackground\"), new ActionDescriptor(), DialogModes.NO);"
            case "content_aware_fill":
                body = """
                try { d.selection.bounds; } catch (e) { throw new Error("Select what should go first."); }
                llPixels(d, false);
                var x = new ActionDescriptor();
                x.putEnumerated(charIDToTypeID("Usng"), charIDToTypeID("FlCn"), stringIDToTypeID("contentAware"));
                x.putBoolean(stringIDToTypeID("contentAwareColorAdaptationFill"), true);
                x.putUnitDouble(charIDToTypeID("Opct"), charIDToTypeID("#Prc"), 100);
                x.putEnumerated(charIDToTypeID("Md  "), charIDToTypeID("BlnM"), charIDToTypeID("Nrml"));
                executeAction(charIDToTypeID("Fl  "), x, DialogModes.NO);
                """
            case "blur":
                body = "llPixels(d, false).applyGaussianBlur(\(clamp(num("amount", 8), 0.1, 250)));"
            case "sharpen":
                body = "llPixels(d, false).applyUnSharpMask(\(clamp(num("amount", 80), 1, 500)), 1.2, 2);"
            case let w: throw PhotoshopError("Photoshop can't \(w.isEmpty ? "do that" : w.replacingOccurrences(of: "_", with: " ")) here.")
            }
        }
        return prelude + """
        llDoc(\(id));
        llRun(\(literal(name)), function (d) {
        \(body)
            return "ok";
        });
        llState(app.activeDocument);
        """
    }
}

public struct PhotoshopError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
