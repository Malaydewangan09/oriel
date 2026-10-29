import AppKit

enum LinkCleaner {
    // Query parameters that only exist to track who clicked.
    private static let trackers: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "mc_eid", "mc_cid", "igshid", "igsh", "si", "ref_src", "ref_url", "yclid", "_hsenc", "_hsmi",
        "mkt_tok", "vero_id", "oly_enc_id", "oly_anon_id", "wickedid", "twclid", "ttclid", "li_fat_id",
    ]

    static func clean(_ s: String) -> String? {
        guard var c = URLComponents(string: s), let items = c.queryItems, !items.isEmpty else { return nil }
        let kept = items.filter { !$0.name.lowercased().hasPrefix("utm_") && !trackers.contains($0.name.lowercased()) }
        guard kept.count < items.count else { return nil }
        c.queryItems = kept.isEmpty ? nil : kept
        return c.string
    }
}

// "Copy as": small text conversions people otherwise do in a browser tab.
enum Transform: String, CaseIterable, Identifiable {
    case plain = "Trimmed plain text", upper = "UPPERCASE", lower = "lowercase", title = "Title Case"
    case jsonPretty = "Pretty JSON", jsonMin = "Minified JSON", urlDecode = "URL-decoded", base64 = "Base64-decoded"
    case links = "Just the links", emails = "Just the emails"
    case joined = "Lines joined", deduped = "Duplicate lines removed", csv = "Table as CSV"
    var id: String { rawValue }

    func apply(_ s: String) -> String? {
        switch self {
        case .plain: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .upper: return s.uppercased()
        case .lower: return s.lowercased()
        case .title: return s.capitalized
        case .jsonPretty, .jsonMin:
            // A bare number or string parses as a fragment, but writing one back raises an exception try? can't catch.
            guard let d = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d), JSONSerialization.isValidJSONObject(obj),
                let out = try? JSONSerialization.data(
                    withJSONObject: obj,
                    options: self == .jsonPretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes])
            else { return nil }
            return String(data: out, encoding: .utf8)
        case .urlDecode: return s.removingPercentEncoding.flatMap { $0 == s ? nil : $0 }
        case .base64:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return Data(base64Encoded: t + String(repeating: "=", count: (4 - t.count % 4) % 4)).flatMap { String(data: $0, encoding: .utf8) }
        case .links, .emails:
            guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
            let found = det.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap(\.url).filter {
                (self == .emails) == ($0.scheme == "mailto")
            }
            .map { self == .emails ? $0.absoluteString.replacingOccurrences(of: "mailto:", with: "") : $0.absoluteString }
            return found.isEmpty ? nil : found.joined(separator: "\n")
        case .joined: return Self.joinWrapped(s)
        case .deduped:
            var seen = Set<String>()
            let lines = s.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).isEmpty || seen.insert($0).inserted }
            return lines.joined(separator: "\n")
        case .csv: return Self.tableToCSV(s)
        }
    }

    // Text copied from a PDF breaks every line. Paragraph breaks stay, words split by a hyphen are mended.
    private static func joinWrapped(_ s: String) -> String? {
        let paragraphs = s.components(separatedBy: "\n\n").map { p -> String in
            var out = ""
            for line in p.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
                if out.isEmpty {
                    out = line
                } else if out.hasSuffix("-"), let f = line.first, f.isLowercase {
                    out.removeLast(); out += line
                } else {
                    out += " " + line
                }
            }
            return out
        }
        let joined = paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return s.contains("\n") ? joined : nil
    }

    // Spreadsheet copies (tab-separated) and Markdown tables become CSV.
    private static func tableToCSV(_ s: String) -> String? {
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        var rows: [[String]]
        if lines.allSatisfy({ $0.contains("\t") }) {
            rows = lines.map { $0.components(separatedBy: "\t") }
        } else if lines.allSatisfy({ $0.hasPrefix("|") }) {
            rows = lines.filter { !$0.allSatisfy { "|-: ".contains($0) } }
                .map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                }
        } else {
            return nil
        }
        guard rows.count >= 2, rows.allSatisfy({ $0.count >= 2 }) else { return nil }
        func cell(_ c: String) -> String {
            c.contains(",") || c.contains("\"") || c.contains("\n") ? "\"" + c.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : c
        }
        return rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\n")
    }

    // Only offer conversions that would change something.
    static func available(for s: String) -> [Transform] { allCases.filter { t in t.apply(s).map { $0 != s } ?? false } }
}
