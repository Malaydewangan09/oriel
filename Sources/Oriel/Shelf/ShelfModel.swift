import AppKit
import Quartz
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

enum Tab: String, CaseIterable, Identifiable {
    case today = "Today", text = "Text", links = "Links", screenshots = "Screenshots", code = "Code", files = "Files", colors = "Colors", pinned =
        "Pinned"
    var id: String { rawValue }

    // Text, Code and Colors share the copy rows, so they are told apart by how each one looks.
    func admits(_ item: Item) -> Bool {
        switch self {
        case .text: if case .text = Look.of(item) { return true }
        case .code: if case .code = Look.of(item) { return true }
        case .colors: if case .color = Look.of(item) { return true }
        default: return true
        }
        return false
    }
}

@MainActor
final class ShelfModel: ObservableObject {
    @Published var tab: Tab = .today {
        didSet { if tab != oldValue || scope != .tab { scope = .tab; reload(animation: .spring(duration: 0.3)) } }
    }
    @Published private(set) var scope: Scope = .tab
    @Published var stacks: [Stack] = []
    @Published var detail: Detail?
    @Published var text = "" { didSet { reload() } }
    @Published private(set) var items: [Item] = []
    @Published private(set) var query = Query()
    @Published private(set) var pinned: Set<Int64> = []
    @Published var selected: Int = 0
    @Published var copiedID: Int64?
    @Published private(set) var caught = 0
    @Published var toast: String?

    // Cards grouped under plain time labels, in display order.
    var sections: [(String, [Item])] {
        let cal = Calendar.current, now = Date()
        var out: [(String, [Item])] = []
        for item in items {
            let label: String
            if now.timeIntervalSince(item.ts) < 300 {
                label = "Just now"
            } else if cal.isDateInToday(item.ts) {
                label = "Earlier today"
            } else if cal.isDateInYesterday(item.ts) {
                label = "Yesterday"
            } else {
                label = item.ts.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
            }
            if out.last?.0 == label { out[out.count - 1].1.append(item) } else { out.append((label, [item])) }
        }
        return out
    }

    // The rail designs (Glass and Next) can show secrets or one stack instead of a tab.
    enum Scope: Equatable { case tab, secrets, stack(String) }
    enum Detail: Equatable { case noticed(Int64), shareSafe(Int64), markup(Int64), claude }

    func show(_ s: Scope) {
        text = ""
        detail = nil
        scope = s
        selected = 0
        reload()
    }

    private let queue = DispatchQueue(label: "oriel.shelf", qos: .userInitiated)
    private var generation = 0

    // Queries run off the main thread so typing never waits on SQLite. Only the latest request is applied.
    func reload(animation: Animation? = nil) {
        let typed = !text.trimmingCharacters(in: .whitespaces).isEmpty
        if case .stack(let id) = scope, !stacks.contains(where: { $0.id == id }) { scope = .tab }
        query = typed ? Query.parse(text) : Query()
        if typed { selected = 0 }
        let (query, scope, tab) = (query, scope, tab)
        let stackIDs = stacks.first { if case .stack(let id) = scope { $0.id == id } else { false } }?.itemIDs ?? []
        generation += 1
        let request = generation
        queue.async {
            let pinned = Store.shared.pinnedIDs()
            let items = Self.fetch(typed: typed, query: query, scope: scope, stackIDs: stackIDs, tab: tab)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard request == self.generation else { return }
                    withAnimation(animation) {
                        self.pinned = pinned
                        self.items = items
                        self.selected = min(self.selected, max(items.count - 1, 0))
                    }
                }
            }
        }
    }

    // A typed search covers everything. Otherwise the scope decides, then the tab.
    private nonisolated static func fetch(typed: Bool, query: Query, scope: Scope, stackIDs: [Int64], tab: Tab) -> [Item] {
        if typed { return Store.shared.search(query, limit: 40) }
        switch scope {
        case .secrets: return Store.shared.search(Query(), limit: 200).filter { $0.secret != nil }
        case .stack:
            var q = Query()
            q.ids = stackIDs
            return Store.shared.search(q, limit: 200)
        case .tab: break
        }
        var q = Query()
        switch tab {
        case .today: q.from = Calendar.current.date(byAdding: .day, value: -2, to: Date())
        case .links: q.kinds = [.link]
        case .screenshots: q.kinds = [.screenshot]
        case .files: q.kinds = [.download]
        case .text, .code, .colors: q.kinds = [.copy]
        case .pinned: q.pinnedOnly = true
        }
        return Array(Store.shared.search(q, limit: 200).lazy.filter { tab.admits($0) }.prefix(40))
    }

    // Called when something new is caught while the shelf is open: slide it in and let the bird hop.
    func didCatch() {
        caught += 1
        reload(animation: .spring(duration: 0.4, bounce: 0.25))
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = max(0, min(items.count - 1, selected + delta))
    }

    var current: Item? { items.indices.contains(selected) ? items[selected] : nil }

    func use(_ item: Item) {
        if let p = item.path { NSWorkspace.shared.open(URL(fileURLWithPath: p)); return }
        copy(item.body, for: item)
    }

    // A stack as one message for an AI chat: each item under a heading saying what it is and where it came from.
    // Secrets are left out. Long items are cut so the message stays usable.
    func copyForAI() {
        guard case .stack(let id) = scope, let stack = stacks.first(where: { $0.id == id }) else { return }
        let blocks = items.sorted { $0.ts < $1.ts }.compactMap(Self.aiBlock)
        guard !blocks.isEmpty else { flash("Nothing to copy"); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("# \(stack.name)\n\n" + blocks.joined(separator: "\n\n"), forType: .string)
        NSPasteboard.general.markOwn()
        flash("Copied \(blocks.count) \(blocks.count == 1 ? "item" : "items") for AI")
    }

    // Hands the stack to Claude Code, read-only, in the folder where its code lives. The answer shows up in the shelf.
    func handToClaude() {
        guard case .stack(let id) = scope, let stack = stacks.first(where: { $0.id == id }) else { return }
        let blocks = items.sorted { $0.ts < $1.ts }.compactMap(Self.aiBlock)
        guard !blocks.isEmpty else { flash("Nothing to hand over"); return }
        let repo = ClaudeAgent.repoName(in: items) ?? stack.name
        guard let folder = ClaudeAgent.folder(for: repo) else { return }
        ClaudeAgent.shared.run(task: stack.name, context: "# \(stack.name)\n\n" + blocks.joined(separator: "\n\n"), in: folder)
        detail = .claude
    }

    nonisolated static func aiBlock(_ item: Item) -> String? {
        guard item.secret == nil else { return nil }
        let from = [item.source ?? item.app, item.ts.formatted(.dateTime.hour().minute())].compactMap { $0 }.joined(separator: ", ")
        func cut(_ s: String) -> String { let r = Secrets.redact(s); return r.count > 6000 ? String(r.prefix(6000)) + "\n…" : r }
        switch Look.of(item) {
        case .code(let s): return "## Code (from \(from))\n```\n\(cut(s))\n```"
        case .text(let s): return "## Text (from \(from))\n\(cut(s))"
        case .link: return "## Link (from \(from))\n" + (item.title.isEmpty || item.title == item.body ? item.body : "\(item.title)\n\(item.body)")
        case .image:
            let text = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "## Screenshot text (\(from))\n" + (text.isEmpty ? "(no text found)" : "```\n\(cut(text))\n```")
        case .file(let u):
            let text = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "## File: \(u.lastPathComponent) (\(from))" + (text.isEmpty ? "" : "\n```\n\(cut(text))\n```")
        case .color(_, let hex): return "## Colour (from \(from))\n\(hex)"
        }
    }

    // What one click does: the thing itself goes on the clipboard, an image as an image and a file as a file.
    func copyPrimary(_ item: Item) {
        if item.isImage { copyImage(item); return }
        if let p = item.path {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([URL(fileURLWithPath: p) as NSURL])
            NSPasteboard.general.markOwn()
            withAnimation(.spring(duration: 0.3, bounce: 0.4)) { copiedID = item.id }
            flash("File copied")
            return
        }
        copy(item.body, for: item)
    }

    func copy(_ string: String, for item: Item, note: String = "Copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        NSPasteboard.general.markOwn()
        withAnimation(.spring(duration: 0.3, bounce: 0.4)) { copiedID = item.id }
        flash(note)
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000); if copiedID == item.id { withAnimation(.easeOut(duration: 0.2)) { copiedID = nil } }
        }
    }

    func copyImage(_ item: Item) {
        guard let p = item.path, let img = NSImage(contentsOfFile: p) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        NSPasteboard.general.markOwn()
        withAnimation(.spring(duration: 0.3, bounce: 0.4)) { copiedID = item.id }
        flash("Image copied")
    }

    func quickLook(_ item: Item) {
        guard let p = item.path, FileManager.default.fileExists(atPath: p) else { flash("Nothing to preview"); return }
        Peek.shared.show(URL(fileURLWithPath: p))
    }

    // Removes the item from Oriel only. A file it points to stays where it is.
    func delete(_ item: Item) {
        Store.shared.delete(item.id)
        reload(animation: .easeOut(duration: 0.2))
        flash("Deleted")
    }

    func togglePin(_ item: Item) {
        let on = !pinned.contains(item.id)
        Store.shared.setPinned(item.id, on)
        flash(on ? "Pinned. Find it under Pinned" : "Unpinned")
        reload(animation: .spring(duration: 0.3))
    }

    func flash(_ s: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = s }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000); if toast == s { withAnimation(.easeOut(duration: 0.2)) { toast = nil } }
        }
    }
}

extension ShelfModel {
    // What each card can do, shown as hover buttons and in the right-click menu.
    func actions(for item: Item, translate: @escaping (String) -> Void) -> [CardAction] {
        if item.secret != nil {
            return [CardAction(title: "Copy", icon: "doc.on.doc") { self.copy(item.body, for: item, note: "Copied. Oriel forgets it soon") }]
        }
        var out: [CardAction] = []
        switch Look.of(item) {
        case .link(_, _):
            if let u = URL(string: item.body), Noticer.isMeeting(u) {
                out.append(CardAction(title: "Join meeting", icon: "video") { NSWorkspace.shared.open(u) })
            }
            if let clean = LinkCleaner.clean(item.body) {
                out.append(
                    CardAction(title: "Copy clean link (trackers removed)", icon: "sparkles") {
                        self.copy(clean, for: item, note: "Clean link copied")
                    })
            }
            out.append(CardAction(title: "Copy link", icon: "doc.on.doc") { self.copy(item.body, for: item, note: "Link copied") })
            out.append(CardAction(title: "Open", icon: "arrow.up.right") { if let u = URL(string: item.body) { NSWorkspace.shared.open(u) } })
        case .color(let color, let hex):
            out.append(
                CardAction(title: "Copy HEX", icon: "number") { self.copy(hex.hasPrefix("#") ? hex : "#" + hex, for: item, note: "HEX copied") })
            let rgb =
                color.usingColorSpace(.sRGB).map {
                    "rgb(\(Int($0.redComponent * 255)), \(Int($0.greenComponent * 255)), \(Int($0.blueComponent * 255)))"
                } ?? hex
            out.append(CardAction(title: "Copy RGB", icon: "paintpalette") { self.copy(rgb, for: item, note: "RGB copied") })
        case .image:
            if !item.body.isEmpty {
                out.append(CardAction(title: "Copy text in image", icon: "text.viewfinder") { self.copy(item.body, for: item, note: "Text copied") })
            }
            out.append(CardAction(title: "Copy image", icon: "photo") { self.copyImage(item) })
            out.append(CardAction(title: "Look closer", icon: "eye") { self.quickLook(item) })
        case .file:
            out.append(CardAction(title: "Open", icon: "arrow.up.right") { self.use(item) })
            out.append(CardAction(title: "Look closer", icon: "eye") { self.quickLook(item) })
            out.append(
                CardAction(title: "Show in Finder", icon: "folder") {
                    if let p = item.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                })
        case .code:
            out.append(CardAction(title: "Copy", icon: "doc.on.doc") { self.copy(item.body, for: item) })
        case .text:
            out.append(CardAction(title: "Copy", icon: "doc.on.doc") { self.copy(item.body, for: item) })
            out.append(CardAction(title: "Translate", icon: "character.bubble") { translate(item.body) })
        }
        out.append(CardAction(title: "AirDrop", icon: "airplayaudio") { Self.airDrop(item) })
        out.append(
            CardAction(title: self.pinned.contains(item.id) ? "Unpin" : "Pin", icon: self.pinned.contains(item.id) ? "pin.slash" : "pin") {
                self.togglePin(item)
            })
        return out
    }

    static func airDrop(_ item: Item) {
        let payload: Any =
            item.path.map { URL(fileURLWithPath: $0) as Any } ?? (item.kind == .link ? (URL(string: item.body) as Any? ?? item.body) : item.body)
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [payload])
    }

    static func provider(for item: Item) -> NSItemProvider {
        if let p = item.path, let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: p)) { return provider }
        if item.kind == .link, let url = URL(string: item.body) { return NSItemProvider(object: url as NSURL) }
        return NSItemProvider(object: item.body as NSString)
    }
}

extension ShelfModel {
    // The bigger view for the selected item: hiding secrets in images, or actions found in text.
    func openDetail() {
        guard let item = current else { return }
        if item.isImage {
            withAnimation(.spring(duration: 0.3)) { detail = .shareSafe(item.id) }
        } else if item.isText {
            withAnimation(.spring(duration: 0.3)) { detail = .noticed(item.id) }
        }
    }
}

struct CardAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let run: () -> Void
}
