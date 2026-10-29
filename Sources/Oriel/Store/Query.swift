import AppKit
import NaturalLanguage

// Turns "links from slack 3 days ago" into visible filters plus the words to search by.
struct Query: Equatable {
    var words: [String] = []  // exact-match terms
    var kinds: [Kind] = []
    var from: Date?
    var to: Date?
    var app: String?
    var chips: [String] = []
    var pinnedOnly = false
    var ids: [Int64]?

    var ftsExpression: String? {
        let clean = words.map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        return clean.isEmpty ? nil : clean.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // The four things Oriel stores, and the everyday words for them. This is the data model, not guesswork.
    static let kindNames: [Kind: [String]] = [
        .link: ["link", "links", "url", "urls"],
        .screenshot: ["screenshot", "screenshots", "screen shot"],
        .download: ["download", "downloads", "downloaded", "file", "files", "pdf", "pdfs"],
        .copy: ["copy", "copies", "snippet", "snippets", "clipboard"],
    ]

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current, sources: [String] = Vocabulary.shared.names) -> Query {
        var q = Query()
        var rest = text

        // 1. Dates. Relative spans ("3 days ago", "last week") are a number and a unit, parsed as a pattern.
        // Everything else ("yesterday", "this morning", "last monday", "oct 12") goes to Apple's date detector.
        let units: [String: Calendar.Component] = ["day": .day, "week": .weekOfYear, "month": .month]
        if let m = rest.range(
            of: #"\b(\d+|a|one|two|three|four|five|six|seven)\s+(day|week|month)s?\s+ago\b"#, options: [.regularExpression, .caseInsensitive])
        {
            let parts = rest[m].lowercased().split(separator: " ")
            let numbers = ["a": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7]
            let n = Int(parts[0]) ?? numbers[String(parts[0])] ?? 1
            let unit = units[String(parts[1].hasSuffix("s") ? parts[1].dropLast() : parts[1])] ?? .day
            let day = calendar.date(byAdding: unit, value: -n, to: calendar.startOfDay(for: now))!
            q.from = day; q.to = calendar.date(byAdding: unit == .day ? .day : unit, value: 1, to: day)
            q.chips.append(String(rest[m]).capitalized)
            rest.removeSubrange(m)
        } else if let m = rest.range(of: #"\b(last|past|this)\s+(week|month)\b"#, options: [.regularExpression, .caseInsensitive]) {
            let parts = rest[m].lowercased().split(separator: " ")
            let unit = units[String(parts[1])] ?? .weekOfYear
            q.from =
                parts[0] == "this"
                ? calendar.dateInterval(of: unit, for: now)?.start
                : calendar.date(byAdding: unit, value: -1, to: calendar.startOfDay(for: now))
            q.chips.append(parts[0] == "this" ? "This \(parts[1])" : "Past \(parts[1])")
            rest.removeSubrange(m)
        } else if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
            let match = detector.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
            let date = match.date, let range = Range(match.range, in: rest)
        {
            let phrase = rest[range].lowercased()
            let start = calendar.startOfDay(for: date)
            q.from = start
            q.to =
                phrase.contains("morning") ? calendar.date(byAdding: .hour, value: 12, to: start) : calendar.date(byAdding: .day, value: 1, to: start)
            q.chips.append(phrase.prefix(1).uppercased() + phrase.dropFirst())
            rest.removeSubrange(range)
        }

        // 2. Where from: any app or site Oriel has actually seen, longest name first.
        let lower = " " + rest.lowercased() + " "
        if let hit = sources.filter({ lower.contains(" \($0) ") }).max(by: { $0.count < $1.count }) {
            q.app = hit
            q.chips.append(hit.capitalized)
            rest = rest.replacingOccurrences(of: hit, with: " ", options: .caseInsensitive)
        }

        // 3. What kind, then the remaining words. Grammar words are dropped by Apple's part-of-speech tagger.
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = rest
        tagger.enumerateTags(in: rest.startIndex..<rest.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) {
            tag, range in
            let word = rest[range].lowercased()
            if let kind = kindNames.first(where: { $0.value.contains(word) })?.key {
                if !q.kinds.contains(kind) { q.kinds.append(kind); q.chips.append(word.capitalized) }
                if word.hasPrefix("pdf") { q.words.append("pdf") }
                return true
            }
            switch tag {
            case .determiner, .pronoun, .preposition, .particle, .conjunction, .interjection, .classifier, .idiom: break
            case .verb, .adverb: break  // "failed", "urgently" are too loose to match exactly
            default: q.words.append(word)  // nouns, numbers, names, unknown words
            }
            return true
        }
        return q
    }
}

// Every app and site name Oriel can recognise in a query, built from real data, refreshed as you work.
final class Vocabulary: @unchecked Sendable {
    static let shared = Vocabulary()
    private let lock = NSLock()
    private var cached: [String] = []

    var names: [String] { lock.lock(); defer { lock.unlock() }; return cached }

    func refresh() {
        var set = Set<String>()
        func addName(_ raw: String) {
            let n = raw.lowercased().replacingOccurrences(of: ".app", with: "")
            guard n.count >= 2 else { return }
            set.insert(n)
            // "Google Chrome" is also "chrome", "Visual Studio Code" is also "code".
            if let last = n.split(separator: " ").last, last.count >= 3, String(last) != n { set.insert(String(last)) }
        }
        for name in Store.shared.knownSources() {
            if name.contains("."), let host = URL(string: "https://\(name)")?.host {
                let labels = host.split(separator: ".")
                if labels.count >= 2 { set.insert(String(labels[labels.count - 2])) }  // github.com -> github, mail.google.com -> google
                set.insert(host)
            } else {
                addName(name)
            }
        }
        for dir in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            for app in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where app.hasSuffix(".app") { addName(app) }
        }
        lock.lock(); cached = Array(set); lock.unlock()
    }
}
