import AppKit
import SwiftUI

// A group of things that belong to the same piece of work.
struct Stack: Identifiable, Equatable {
    let id: String  // "auto:<key>" or "m:<row id>"
    let name: String
    let itemIDs: [Int64]
    let auto: Bool
    var latest: Date = .distantPast

    var color: Color {
        let palette: [Color] = [.teal, .pink, .purple, .green, .orange, .blue, .mint, .indigo]
        return palette[abs(name.hashValue) % palette.count]
    }

    var manualID: Int64? { auto ? nil : Int64(id.dropFirst(2)) }
}

// Auto stacks come from shared identifiers: a PR or issue number, a ticket key like ENG-142, a Figma file.
// Two or more items from the last week sharing one make a stack. Nothing is guessed from loose words.
enum Stacks {
    private static let notTickets: Set<String> = [
        "UTF", "ISO", "SHA", "RFC", "MD", "AES", "RSA", "HTTP", "TLS", "SSL", "IPV", "MP", "COVID", "GPT", "WCAG", "ES", "X", "A", "B",
    ]

    static func keys(_ item: Item) -> [String: String] {
        guard item.secret == nil else { return [:] }
        let text = item.title + "\n" + item.body
        var out: [String: String] = [:]  // key -> display name
        for m in matches(#"(?:github\.com|gitlab\.com)/([\w.-]+)/([\w.-]+)/(?:pull|issues|-/merge_requests|-/issues)/(\d+)"#, in: text) {
            out["#\(m[3])"] = "\(m[2]) #\(m[3])"
        }
        for m in matches(#"\b([A-Z][A-Z0-9]{1,9})-(\d{1,6})\b"#, in: text) where !notTickets.contains(m[1]) {
            out["\(m[1])-\(m[2])"] = "\(m[1])-\(m[2])"
        }
        if case .color = Look.of(item) {
        } else {
            for m in matches(#"(?<![\w#&])#(\d{2,6})\b"#, in: text) where out["#\(m[1])"] == nil { out["#\(m[1])"] = "#\(m[1])" }
        }
        for m in matches(#"figma\.com/(?:file|design|proto)/[A-Za-z0-9]+/([^?/\s]+)"#, in: text) {
            let name = (m[1].removingPercentEncoding ?? m[1]).replacingOccurrences(of: "-", with: " ")
            out["figma:\(name.lowercased())"] = name
        }
        return out
    }

    static func auto(from items: [Item]) -> [Stack] {
        var groups: [String: (name: String, items: [Item])] = [:]
        for item in items {
            for (key, name) in keys(item) {
                var g = groups[key] ?? (name, [])
                // A repo-qualified name beats a bare "#482".
                if name.count > g.name.count { g.name = name }
                if !g.items.contains(where: { $0.id == item.id }) { g.items.append(item) }
                groups[key] = g
            }
        }
        var seen = Set<[Int64]>()
        return groups.compactMap { key, g -> Stack? in
            let ids = g.items.map(\.id).sorted()
            guard ids.count >= 2, seen.insert(ids).inserted else { return nil }
            return Stack(id: "auto:\(key)", name: g.name, itemIDs: ids, auto: true, latest: g.items.map(\.ts).max() ?? .distantPast)
        }
        .sorted { $0.latest > $1.latest }
        .prefix(5).map { $0 }
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
}

extension ShelfModel {
    func refreshStacks() {
        var q = Query()
        q.from = Calendar.current.date(byAdding: .day, value: -7, to: Date())
        let recent = Store.shared.search(q, limit: 500)
        var auto = Stacks.auto(from: recent)
        // A kept stack named like an auto one takes in its matches too, so collecting into it never splits a task in two.
        let manual = Store.shared.manualStacks().map { m -> Stack in
            var ids = m.items
            if let i = auto.firstIndex(where: { $0.name.lowercased() == m.name.lowercased() }) {
                ids = Array(Set(ids + auto[i].itemIDs)).sorted()
                auto.remove(at: i)
            }
            return Stack(id: "m:\(m.id)", name: m.name, itemIDs: ids, auto: false)
        }
        stacks = manual + auto
        if let id = Self.collectingID, !manual.contains(where: { $0.manualID == id }) { stopCollecting(quietly: true) }
    }

    // "Collect here": everything copied next goes into this stack, matching or not, until it's turned off.
    static var collectingID: Int64? {
        let v = UserDefaults.standard.object(forKey: Pref.collectInto) as? Int64
        return v ?? (UserDefaults.standard.object(forKey: Pref.collectInto) as? Int).map(Int64.init)
    }

    func isCollecting(_ stack: Stack) -> Bool { stack.manualID != nil && stack.manualID == Self.collectingID }

    func collect(into stack: Stack) {
        var id = stack.manualID
        if id == nil {
            // An auto stack becomes a kept one with the same name, so copies that don't match can join it.
            let made = Store.shared.createStack(String(stack.name.prefix(60)))
            for item in stack.itemIDs { Store.shared.setInStack(made, item: item, true) }
            id = made
        }
        guard let id else { return }
        UserDefaults.standard.set(id, forKey: Pref.collectInto)
        UserDefaults.standard.set(stack.name, forKey: Pref.collectName)
        refreshStacks()
        if stack.auto { show(.stack("m:\(id)")) }
        objectWillChange.send()
        flash("Your next copies go into \(stack.name)")
    }

    func stopCollecting(quietly: Bool = false) {
        UserDefaults.standard.removeObject(forKey: Pref.collectInto)
        UserDefaults.standard.removeObject(forKey: Pref.collectName)
        objectWillChange.send()
        if !quietly { flash("Stopped collecting") }
    }

    // Called for every new catch while collecting. Secrets never join a stack.
    func collectIfOn(_ item: Item) {
        guard let id = Self.collectingID, item.id > 0, item.secret == nil, item.source != ClaudeAgent.source else { return }
        Store.shared.setInStack(id, item: item.id, true)
        refreshStacks()
    }

    func newStack(_ name: String, with item: Item) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let id = Store.shared.createStack(String(clean.prefix(60)))
        Store.shared.setInStack(id, item: item.id, true)
        refreshStacks()
        flash("Added to \(clean)")
    }

    func toggle(_ item: Item, in stack: Stack) {
        guard let id = stack.manualID else { return }
        let on = !stack.itemIDs.contains(item.id)
        Store.shared.setInStack(id, item: item.id, on)
        refreshStacks()
        if scope == .stack(stack.id) { reload() }
        flash(on ? "Added to \(stack.name)" : "Removed from \(stack.name)")
    }

    func delete(_ stack: Stack) {
        guard let id = stack.manualID else { return }
        if id == Self.collectingID { stopCollecting(quietly: true) }
        Store.shared.deleteStack(id)
        refreshStacks()
        if scope == .stack(stack.id) { show(.tab) }
    }

    // Live secrets and the seconds until the soonest is forgotten.
    var secretsLeft: (count: Int, soonest: Int) {
        let live = Store.shared.search(Query(), limit: 200).filter { $0.secret != nil }
        let soonest = live.compactMap(\.expires).min().map { max(0, Int($0.timeIntervalSinceNow)) } ?? 0
        return (live.count, soonest)
    }
}
