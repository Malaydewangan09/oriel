import AppKit
import SwiftUI

enum Kind: String, CaseIterable { case copy, link, download, screenshot }

extension Kind {
    var icon: String {
        switch self {
        case .copy: "doc.on.clipboard";
        case .link: "link";
        case .download: "arrow.down.doc";
        case .screenshot: "camera.viewfinder"
        }
    }

    var tint: Color {
        switch self {
        case .copy: .orange;
        case .link: .blue;
        case .download: .green;
        case .screenshot: .purple
        }
    }
}

struct Item: Identifiable, Hashable {
    let id: Int64
    let kind: Kind
    let ts: Date
    let app: String?
    let title: String
    let body: String
    let path: String?
    let source: String?
    var secret: String? = nil  // e.g. "GitHub token". Secrets are shown blurred and forgotten soon.
    var expires: Date? = nil
}

extension Notification.Name {
    // Posted on the main thread whenever Sill keeps something new.
    static let sillCaught = Notification.Name("sill.caught")
}

// How a card looks. Derived from what the item is, so the stored data stays simple.
enum Look: Equatable {
    case link(host: String, path: String)
    case code(String)
    case color(NSColor, hex: String)
    case text(String)
    case image(URL)
    case file(URL)

    static func of(_ item: Item) -> Look {
        if item.kind == .screenshot, let p = item.path { return .image(URL(fileURLWithPath: p)) }
        if item.kind == .download, let p = item.path {
            let ext = (p as NSString).pathExtension.lowercased()
            return ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(ext) ? .image(URL(fileURLWithPath: p)) : .file(URL(fileURLWithPath: p))
        }
        let t = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.kind == .link, let u = URL(string: t), let host = u.host {
            let path = u.path.split(separator: "/").suffix(2).joined(separator: " / ")
            return .link(host: host.replacingOccurrences(of: "www.", with: ""), path: path)
        }
        if let c = hexColor(t) { return .color(c, hex: t.uppercased()) }
        if looksLikeCode(t) { return .code(t) }
        return .text(t)
    }

    static func hexColor(_ s: String) -> NSColor? {
        guard s.range(of: #"^#?([0-9a-fA-F]{6})$"#, options: .regularExpression) != nil else { return nil }
        let v = UInt32(s.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        return NSColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    // Code tends to have brackets, semicolons, arrows or keywords at line starts, and little ordinary prose.
    static func looksLikeCode(_ s: String) -> Bool {
        let signals = [
            #"[{};]\s*$"#, #"=>|->|::|==|!=|&&|\|\|"#,
            #"^\s*(func|def|class|import|const|let|var|return|if|for|SELECT|FROM|public|private|fn|package)\b"#, #"\w+\([^)]*\)"#,
        ]
        let range = NSRange(s.startIndex..., in: s)
        let hits = signals.filter { (try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]))?.firstMatch(in: s, range: range) != nil }
            .count
        return hits >= 2 || (s.contains("\n") && hits >= 1 && s.filter { $0 == " " }.count < s.count / 3)
    }
}

extension Item {
    var lookLabel: String {
        if let secret { return "\(secret) · kept briefly" }
        return switch Look.of(self) {
        case .link: "Link"
        case .code: "Code"
        case .color: "Color"
        case .text: "Text"
        case .image: kind == .screenshot ? (body.isEmpty ? "Screenshot" : "Screenshot · text found") : "Image"
        case .file(let u): u.pathExtension.uppercased().isEmpty ? "File" : u.pathExtension.uppercased()
        }
    }

    var lookIcon: String {
        if secret != nil { return "lock.fill" }
        return switch Look.of(self) {
        case .link: "link";
        case .code: "chevron.left.forwardslash.chevron.right";
        case .color: "paintpalette"
        case .text: "text.quote";
        case .image: "camera.viewfinder";
        case .file: "doc.richtext"
        }
    }

    var lookTint: Color {
        if secret != nil { return .orange }
        return switch Look.of(self) {
        case .link: .blue;
        case .code: .purple;
        case .color: .orange;
        case .text: .brown;
        case .image: .pink
        case .file: Swatch.teal
        }
    }

    var isImage: Bool { if case .image = Look.of(self) { return true }; return false }
    var isText: Bool { path == nil && secret == nil && kind != .link }
}

extension Item {
    // What a row says: the start of the text, or the name of the thing.
    var rowLine: String {
        if secret != nil { return lookLabel }
        switch Look.of(self) {
        case .image:
            let first = body.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if !first.isEmpty { return "Screenshot: \(first)" }
            // The thumbnail already says "image", so the row names the file instead.
            let name = ((path ?? title) as NSString).lastPathComponent
            let shot = ["Screenshot", "Screen Shot", "CleanShot"].contains { name.hasPrefix($0) }
            return shot || name.isEmpty ? lookLabel : (name as NSString).deletingPathExtension
        case .file(let u): return u.lastPathComponent
        case .color(_, let hex): return hex.hasPrefix("#") ? hex : "#" + hex
        default:
            return body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? lookLabel
        }
    }

    var rowMeta: String {
        [origin, ts.formatted(.dateTime.hour().minute())].compactMap { $0 }.joined(separator: " · ")
    }

    static let notchSource = "Dropped on the notch"
    // System helpers that briefly hold focus while you copy. Their names mean nothing to people.
    private static let hiddenOrigins: Set<String> = [
        "UserNotificationCenter", "loginwindow", "SecurityAgent", "CoreServicesUIAgent", "universalAccessAuthWarn",
    ]

    // Where it came from, short enough for a row.
    var origin: String? {
        if source == Self.notchSource { return "Notch" }
        guard let name = source ?? app, !Self.hiddenOrigins.contains(name) else { return nil }
        return name
    }

    // "2:19 AM" today, "Yesterday, 2:19 AM", then the weekday, matching the list's section labels.
    var when: String {
        let cal = Calendar.current, time = ts.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(ts) { return time }
        if cal.isDateInYesterday(ts) { return "Yesterday, \(time)" }
        return ts.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
