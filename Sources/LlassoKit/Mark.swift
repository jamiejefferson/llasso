import CoreGraphics
import Foundation

/// The Llasso mark: a figure-of-eight lasso with a trailing rope, drawn by JJ (llassollogo.svg).
public enum LassoMark {
    /// The mark's size in its own units.
    public static let size = CGSize(width: 646, height: 373)

    public static let pathData = "M507.72 0C549.147 1.71696e-05 583.19 8.73901 607.45 26.3066C632.483 44.4337 645.305 70.7469 645.305 100.655C645.305 130.541 632.24 157.679 607.564 176.823C583.297 195.65 549.176 205.785 507.72 205.785C468.503 205.785 424.581 196.667 390.124 190.038C387.832 195.094 383.553 199.239 377.896 201.207C375.345 202.094 372.621 203.05 369.785 204.027C368.702 232.325 361.944 254.52 350.301 272.296C337.64 291.625 320.508 303.707 303.83 312.819C295.555 317.341 287.022 321.321 279.111 324.998C271.001 328.767 263.534 332.222 256.375 336.039C242.194 343.6 230.813 351.786 222.404 363.368C215.59 372.753 202.457 374.838 193.072 368.024C183.687 361.21 181.603 348.078 188.417 338.693C202.121 319.817 219.739 307.975 236.615 298.978C244.986 294.515 253.563 290.557 261.409 286.91C269.454 283.171 276.79 279.733 283.691 275.962C297.368 268.489 307.826 260.491 315.167 249.283C320.588 241.006 325.039 229.847 326.943 213.822C321.485 213.808 315.34 212.964 309.474 210.154C298.595 204.943 292.612 195.005 291.307 183.803C290.165 174.006 291.86 163.129 299.675 154.337C304.381 149.042 310.134 145.863 315.73 143.93C314.901 142.048 314.025 140.157 313.1 138.26L347.429 113.146C352.662 122.946 356.884 132.777 360.196 142.363C366.128 143.121 372.143 144.081 378.07 145.102C418.784 152.11 465.551 163.785 507.72 163.785C542.743 163.785 566.914 155.203 581.819 143.64C596.316 132.393 603.305 117.467 603.305 100.655C603.305 83.8665 596.663 70.3511 582.817 60.3252C568.199 49.7399 543.948 42 507.72 42C443.333 42.0001 394.159 71.4822 344.192 107.314C344.194 107.317 344.196 107.32 344.197 107.323L310.045 132.309C310.041 132.301 310.037 132.294 310.033 132.287C260.223 168.74 205.307 205.785 134.731 205.785C90.3494 205.785 56.4371 194.942 33.3125 175.119C9.86235 155.018 0.000120108 127.801 0 100.655C0 39.5529 60.2825 0.000118918 134.731 0C219.566 0 277.652 29.3718 314.969 68.3281L280.688 93.4062C251.507 65.012 205.545 42 134.731 42C70.3408 42.0001 42 73.9979 42 100.655C42.0001 117.389 47.822 132.238 60.6465 143.231C73.7969 154.504 96.7511 163.785 134.731 163.785C190.972 163.785 235.389 134.669 285.427 98.2119C285.406 98.1903 285.386 98.169 285.365 98.1475L319.478 73.1924C319.503 73.221 319.529 73.2496 319.555 73.2783C370.813 36.4193 429.614 6.64171e-05 507.72 0Z"

    /// The mark fitted into `rect`, keeping its proportions. `flipped` gives y-down
    /// coordinates (SwiftUI); leave it false for AppKit and Core Animation (y-up).
    public static func path(in rect: CGRect, flipped: Bool = false) -> CGPath {
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        var t = CGAffineTransform(translationX: rect.midX - w / 2, y: rect.midY - h / 2).scaledBy(x: scale, y: scale)
        if !flipped { t = t.translatedBy(x: 0, y: size.height).scaledBy(x: 1, y: -1) }
        let base = SVGPath.parse(pathData)
        return base.copy(using: &t) ?? base
    }
}

/// Reads the subset of SVG path syntax the mark uses: M, L, H, V, C and Z, absolute or relative.
public enum SVGPath {
    public static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens = tokenize(d)[...]
        var command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero

        func number() -> CGFloat? {
            guard case .number(let n)? = tokens.first else { return nil }
            tokens = tokens.dropFirst()
            return CGFloat(n)
        }
        func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while let token = tokens.first {
            if case .command(let c) = token {
                command = c
                tokens = tokens.dropFirst()
            }
            let rel = command.isLowercase
            switch command.uppercased().first! {
            case "M":
                guard let p = point(relative: rel) else { return path }
                path.move(to: p)
                current = p; start = p
                command = rel ? "l" : "L"   // further pairs are line-tos
            case "L":
                guard let p = point(relative: rel) else { return path }
                path.addLine(to: p)
                current = p
            case "H":
                guard let x = number() else { return path }
                current = CGPoint(x: rel ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case "V":
                guard let y = number() else { return path }
                current = CGPoint(x: current.x, y: rel ? current.y + y : y)
                path.addLine(to: current)
            case "C":
                guard let c1 = point(relative: rel), let c2 = point(relative: rel), let p = point(relative: rel) else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
            case "Z":
                path.closeSubpath()
                current = start
                if case .number? = tokens.first { return path }   // malformed: stop rather than loop
            default:
                return path
            }
        }
        return path
    }

    enum Token { case command(Character), number(Double) }

    static func tokenize(_ d: String) -> [Token] {
        var out: [Token] = []
        var num = ""
        func flush() {
            if let n = Double(num) { out.append(.number(n)) }
            num = ""
        }
        var previous: Character = " "
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                flush()
                out.append(.command(ch))
            } else if ch == "-" && !(previous == "e" || previous == "E") {
                flush()
                num = "-"
            } else if ch == "." && num.contains(".") && !num.contains("e") {
                flush()
                num = "."
            } else if ch == " " || ch == "," || ch == "\n" || ch == "\t" {
                flush()
            } else {
                num.append(ch)
            }
            previous = ch
        }
        flush()
        return out
    }
}
