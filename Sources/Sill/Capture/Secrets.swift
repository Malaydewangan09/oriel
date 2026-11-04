import Foundation

// Recognises credentials by their well-known shapes. Matches are kept briefly and never indexed.
enum Secrets {
    static let lifetime: TimeInterval = 120
    private static let patterns: [(String, String)] = [
        ("AWS key", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("GitHub token", #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#),
        ("GitHub token", #"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#),
        ("Anthropic key", #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#),
        ("OpenAI key", #"\bsk-(proj-)?[A-Za-z0-9_\-]{20,}"#),
        ("Stripe key", #"\b(sk|rk)_(live|test)_[A-Za-z0-9]{16,}\b"#),
        ("Slack token", #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
        ("Google key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        ("JWT", #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),
        ("Private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
    ]

    // Every credential in the text, with where it sits. Used to hide them in screenshots.
    static func matches(in text: String) -> [(name: String, range: Range<String.Index>)] {
        var out: [(name: String, range: Range<String.Index>)] = []
        for (name, p) in patterns {
            var from = text.startIndex
            while let r = text.range(of: p, options: .regularExpression, range: from..<text.endIndex) {
                if !out.contains(where: { $0.range.overlaps(r) }) { out.append((name, r)) }
                from = r.upperBound
            }
        }
        if let r = text.range(of: #"\b(?:\d[ -]?){13,19}\b"#, options: .regularExpression), cardNumber(in: String(text[r])) {
            out.append(("Card number", r))
        }
        return out
    }

    // The text with every credential, and any password inside a link, replaced by a marker. For text that leaves the Mac.
    static func redact(_ text: String) -> String {
        var out = text
        for m in matches(in: text).sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(m.range, with: "[\(m.name) hidden]")
        }
        return out.replacingOccurrences(of: #"(\w+://[^\s:/@]+):[^\s@/]+@"#, with: "$1:[password hidden]@", options: .regularExpression)
    }

    static func kind(of text: String) -> String? {
        for (name, p) in patterns where text.range(of: p, options: .regularExpression) != nil { return name }
        return cardNumber(in: text) ? "Card number" : nil
    }

    // 13 to 19 digits that pass the Luhn check, the format every payment card uses.
    private static func cardNumber(in text: String) -> Bool {
        guard let r = text.range(of: #"\b(?:\d[ -]?){13,19}\b"#, options: .regularExpression) else { return false }
        let digits = text[r].compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { acc, p in
            let d = p.offset % 2 == 1 ? p.element * 2 : p.element
            return acc + (d > 9 ? d - 9 : d)
        }
        return sum % 10 == 0
    }
}
