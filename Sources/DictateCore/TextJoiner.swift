import Foundation

public enum TextJoiner: Sendable {
    public static func join(_ parts: [String]) -> String {
        var out = ""
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if out.isEmpty {
                out = part
                continue
            }
            if needsSpace(between: out, and: part) {
                out += " " + part
            } else {
                out += part
            }
        }
        return out
    }

    static func needsSpace(between left: String, and right: String) -> Bool {
        guard let a = left.last, let b = right.first else { return false }
        if a.isWhitespace || b.isWhitespace { return false }
        if b.isPunctuation { return false }
        if isCJK(a) && isCJK(b) { return false }
        return true
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x3040...0x30FF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }
}
