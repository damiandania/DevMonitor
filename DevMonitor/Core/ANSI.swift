import SwiftUI

/// Minimal ANSI SGR parser: turns a line with ANSI color escapes into a colored
/// AttributedString, and strips escapes for plain-text matching.
enum ANSI {
    static func attributed(_ input: String) -> AttributedString {
        guard input.contains("\u{1b}[") else { return AttributedString(input) }

        var result = AttributedString()
        var color: Color?
        var bold = false
        var buffer = ""
        let chars = Array(input)
        var i = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            var piece = AttributedString(buffer)
            if let color { piece.foregroundColor = color }
            if bold { piece.inlinePresentationIntent = .stronglyEmphasized }
            result.append(piece)
            buffer = ""
        }

        while i < chars.count {
            if chars[i] == "\u{1b}", i + 1 < chars.count, chars[i + 1] == "[" {
                flush()
                var j = i + 2
                var code = ""
                while j < chars.count, !chars[j].isLetter {
                    code.append(chars[j]); j += 1
                }
                if j < chars.count, chars[j] == "m" {
                    applySGR(code, color: &color, bold: &bold)
                }
                i = (j < chars.count) ? j + 1 : j   // consume the terminator
            } else {
                buffer.append(chars[i])
                i += 1
            }
        }
        flush()
        return result
    }

    private static func applySGR(_ code: String, color: inout Color?, bold: inout Bool) {
        let parts = code.isEmpty ? ["0"] : code.split(separator: ";").map(String.init)
        for part in parts {
            switch Int(part) ?? -1 {
            case 0: color = nil; bold = false
            case 1: bold = true
            case 22: bold = false
            case 39: color = nil
            case 30, 90: color = .gray
            case 31, 91: color = .red
            case 32, 92: color = .green
            case 33, 93: color = .yellow
            case 34, 94: color = .blue
            case 35, 95: color = .purple
            case 36, 96: color = .cyan
            case 37, 97, 38: color = nil
            default: break
            }
        }
    }
}

extension String {
    /// The string with ANSI escape sequences removed.
    var strippedANSI: String {
        replacingOccurrences(of: "\u{1b}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
    }
}
