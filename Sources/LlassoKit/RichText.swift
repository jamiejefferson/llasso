import Foundation

/// Puts new text into the HTML an app copied for the selection, keeping its tags and styles,
/// so a replacement pasted back keeps the document's headings, fonts and emphasis.
public enum RichText {
    enum Token: Equatable { case tag(String), text(String) }

    static let blockTags: Set<String> = ["p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "td", "th",
                                         "blockquote", "pre", "ul", "ol", "table", "br"]

    static func tokenize(_ html: String) -> [Token] {
        var out: [Token] = []
        var i = html.startIndex
        while i < html.endIndex {
            if html[i] == "<", let close = html[i...].firstIndex(of: ">") {
                out.append(.tag(String(html[i...close])))
                i = html.index(after: close)
            } else {
                let next = html[i...].firstIndex(of: "<") ?? html.endIndex
                let stop = next == i ? html.index(after: i) : next
                out.append(.text(String(html[i..<stop])))
                i = stop
            }
        }
        return out
    }

    static func tagName(_ tag: String) -> String {
        tag.dropFirst().drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
    }

    static func decode(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
        while let m = r.range(of: "&#[0-9]+;", options: .regularExpression),
              let n = UInt32(r[m].dropFirst(2).dropLast()), let u = Unicode.Scalar(n) {
            r.replaceSubrange(m, with: String(Character(u)))
        }
        return r.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Tokens inside <style>, <script> and <head> aren't content.
    static func contentMask(_ tokens: [Token]) -> [Bool] {
        var hidden = 0
        return tokens.map { t in
            guard case .tag(let tag) = t else { return hidden == 0 }
            let name = tagName(tag)
            if ["style", "script", "head", "title"].contains(name) {
                if tag.hasPrefix("</") { hidden = max(0, hidden - 1) } else if !tag.hasSuffix("/>") { hidden += 1 }
            }
            return false
        }
    }

    /// The visible text, whitespace collapsed, for comparing.
    public static func plain(_ html: String) -> String {
        let tokens = tokenize(html)
        let mask = contentMask(tokens)
        var s = ""
        for (t, visible) in zip(tokens, mask) {
            switch t {
            case .text(let x) where visible: s += decode(x)
            case .tag(let tag) where blockTags.contains(tagName(tag)): s += " "
            default: break
            }
        }
        return normalise(s)
    }

    public static func normalise(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The tags in order: what must survive a rewrite unchanged.
    public static func skeleton(_ html: String) -> [String] {
        tokenize(html).compactMap { if case .tag(let t) = $0 { return t }; return nil }
    }

    /// Indices of visible, non-blank text tokens, grouped by block (paragraph, heading, list item, line break).
    static func blocks(_ tokens: [Token]) -> [[Int]] {
        let mask = contentMask(tokens)
        var groups: [[Int]] = [[]]
        for (i, t) in tokens.enumerated() {
            switch t {
            case .tag(let tag) where blockTags.contains(tagName(tag)):
                if !(groups.last?.isEmpty ?? true) { groups.append([]) }
            case .text(let x) where mask[i] && !decode(x).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                groups[groups.count - 1].append(i)
            default: break
            }
        }
        return groups.filter { !$0.isEmpty }
    }

    static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether every paragraph is a single styled run, so a paragraph-for-paragraph swap loses nothing.
    public static func isSimple(_ html: String) -> Bool {
        blocks(tokenize(html)).allSatisfy { $0.count == 1 }
    }

    /// Paragraph-for-paragraph: each paragraph's new text takes the place of its first run, so
    /// paragraph and first-run styles (heading, size, font) carry over. Nil when the paragraph
    /// counts differ, since then there's no telling which style belongs to which line.
    public static func swapParagraphs(_ html: String, with text: String) -> String? {
        var tokens = tokenize(html)
        let groups = blocks(tokens)
        let paras = paragraphs(text)
        guard !groups.isEmpty, groups.count == paras.count else { return nil }
        for (group, para) in zip(groups, paras) {
            for (n, i) in group.enumerated() { tokens[i] = .text(n == 0 ? escape(para) : "") }
        }
        return tokens.map { if case .tag(let t) = $0 { return t }; if case .text(let x) = $0 { return x }; return "" }.joined()
    }

    /// A model's rewrite counts only if it kept every tag exactly and says exactly the new text.
    public static func isFaithful(_ rewritten: String, original: String, text: String) -> Bool {
        skeleton(rewritten) == skeleton(original) && plain(rewritten) == normalise(text)
    }

    public static let rewritePrompt = """
    You receive the HTML an app copied for a selection, and the text that should replace it. \
    Return the same HTML with only the text between tags changed so it reads as the new text. \
    Keep every tag and attribute exactly, in the same order; do not add, drop or move any tag. \
    Put each word inside the tags that styled the matching words before (a bold phrase stays bold). \
    Use the new text word for word. Reply with the HTML only, no code fence.
    """
}
