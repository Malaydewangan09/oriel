import AppKit
import SwiftUI

// Something in copied text Sill can act on, found with Apple's data detectors plus a few well-known formats.
struct Notice: Identifiable {
    enum Kind { case event, meeting, parcel, flight, place, phone, email, link }
    let id = UUID()
    let kind: Kind
    let range: NSRange
    let title: String
    let hint: String
    let action: String
    let url: URL?  // what the action opens; events are written to an .ics file instead
    var start: Date?
    var duration: TimeInterval = 1800

    var icon: String {
        switch kind {
        case .event: "calendar.badge.plus";
        case .meeting: "video";
        case .parcel: "shippingbox";
        case .flight: "airplane"
        case .place: "map";
        case .phone: "phone";
        case .email: "envelope";
        case .link: "link"
        }
    }
}

enum Noticer {
    private static let meetingHosts = [
        "meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "whereby.com", "meet.jit.si", "webex.com", "around.co",
    ]

    static func isMeeting(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func find(in text: String, now: Date = Date()) -> [Notice] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var out: [Notice] = []
        let types: NSTextCheckingResult.CheckingType = [.date, .address, .phoneNumber, .link, .transitInformation]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }

        for m in detector.matches(in: text, range: all) {
            let raw = ns.substring(with: m.range)
            switch m.resultType {
            case .date:
                guard let date = m.date, date > now.addingTimeInterval(-3600), date < now.addingTimeInterval(365 * 86_400) else { continue }
                var n = Notice(
                    kind: .event, range: m.range, title: eventTitle(text, around: m.range),
                    hint: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()),
                    action: "Add to Calendar", url: nil, start: date)
                if m.duration > 0 { n.duration = m.duration }
                out.append(n)
            case .link:
                guard let url = m.url else { continue }
                if url.scheme == "mailto" {
                    out.append(
                        Notice(
                            kind: .email, range: m.range, title: raw.replacingOccurrences(of: "mailto:", with: ""), hint: "Opens in Mail",
                            action: "Write email", url: url))
                } else if isMeeting(url) {
                    out.append(Notice(kind: .meeting, range: m.range, title: raw, hint: url.host ?? "", action: "Join meeting", url: url))
                } else {
                    out.append(Notice(kind: .link, range: m.range, title: raw, hint: url.host ?? "", action: "Open link", url: url))
                }
            case .address:
                let place = raw.replacingOccurrences(of: "\n", with: ", ")
                out.append(
                    Notice(
                        kind: .place, range: m.range, title: place, hint: "Opens in Maps", action: "Open in Maps",
                        url: URL(string: "http://maps.apple.com/?q=" + (place.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))))
            case .phoneNumber:
                let digits = (m.phoneNumber ?? raw).filter { $0.isNumber || $0 == "+" }
                guard digits.filter(\.isNumber).count >= 7 else { continue }
                out.append(
                    Notice(
                        kind: .phone, range: m.range, title: raw, hint: "Through your iPhone, with FaceTime", action: "Call",
                        url: URL(string: "tel:" + digits)))
            case .transitInformation:
                let c = m.components ?? [:]
                let flight = [c[.airline], c[.flight]].compactMap { $0 }.joined(separator: " ")
                guard !flight.isEmpty else { continue }
                out.append(
                    Notice(
                        kind: .flight, range: m.range, title: "Flight \(flight)", hint: "Live status on the web", action: "Flight status",
                        url: URL(
                            string: "https://www.google.com/search?q=" + ("flight " + flight).addingPercentEncoding(
                                withAllowedCharacters: .urlQueryAllowed)!)))
            default: break
            }
        }
        out += parcels(in: text)

        // An event picks up a meeting link from the same text.
        if let meet = out.first(where: { $0.kind == .meeting }) {
            for i in out.indices where out[i].kind == .event {
                out[i] = Notice(
                    kind: .event, range: out[i].range, title: out[i].title, hint: out[i].hint + ", with the meeting link", action: out[i].action,
                    url: meet.url, start: out[i].start, duration: out[i].duration)
            }
        }
        return out.sorted { order($0.kind) < order($1.kind) }
    }

    private static func order(_ k: Notice.Kind) -> Int {
        switch k {
        case .event: 0;
        case .meeting: 1;
        case .flight: 2;
        case .parcel: 3;
        case .place: 4;
        case .phone: 5;
        case .email: 6;
        case .link: 7
        }
    }

    // Carrier formats that are unambiguous, plus any code that follows the word "tracking" or "AWB".
    private static func parcels(in text: String) -> [Notice] {
        let ns = text as NSString
        let rules: [(String, String, Int)] = [
            (#"\b1Z[0-9A-Z]{16}\b"#, "UPS", 0),
            (#"\b9[2-5]\d{20}\b"#, "USPS", 0),
            (#"(?i)\b(?:tracking|awb|consignment)\s*(?:no\.?|number|id|#)?\s*[:#]?\s*([A-Z0-9]{8,22})\b"#, "Courier", 1),
        ]
        var out: [Notice] = [], seen = Set<String>()
        for (pattern, carrier, group) in rules {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range(at: group)
                let code = ns.substring(with: r)
                guard code.contains(where: \.isNumber), seen.insert(code).inserted else { continue }
                out.append(
                    Notice(
                        kind: .parcel, range: r, title: "Parcel \(code)", hint: carrier, action: "Track parcel",
                        url: URL(string: "https://parcelsapp.com/en/tracking/\(code)")))
            }
        }
        return out
    }

    // The sentence the date sits in, trimmed, as a starting title the user can rename in Calendar.
    private static func eventTitle(_ text: String, around range: NSRange) -> String {
        let ns = text as NSString
        var start = range.location, end = range.location + range.length
        let stops = CharacterSet(charactersIn: ".!?\n")
        while start > 0, let u = UnicodeScalar(ns.character(at: start - 1)), !stops.contains(u) { start -= 1 }
        while end < ns.length, let u = UnicodeScalar(ns.character(at: end)), !stops.contains(u) { end += 1 }
        let sentence = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)
        return sentence.count > 80 ? String(sentence.prefix(79)) + "…" : sentence
    }

    static func run(_ n: Notice) {
        if n.kind == .event, let start = n.start { addToCalendar(title: n.title, start: start, duration: n.duration, url: n.url); return }
        if let url = n.url { NSWorkspace.shared.open(url) }
    }

    // Calendar opens the .ics and asks which calendar to add it to. No Calendar permission needed.
    private static func addToCalendar(title: String, start: Date, duration: TimeInterval, url: URL?) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Sill//EN", "BEGIN:VEVENT", "UID:\(UUID().uuidString)", "DTSTAMP:\(f.string(from: Date()))",
            "DTSTART:\(f.string(from: start))", "DTEND:\(f.string(from: start.addingTimeInterval(duration)))", "SUMMARY:\(esc(title))",
        ]
        if let url { lines += ["URL:\(url.absoluteString)", "LOCATION:\(esc(url.absoluteString))"] }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Sill", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("event-\(Int(start.timeIntervalSince1970)).ics")
        guard (try? lines.joined(separator: "\r\n").write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        NSWorkspace.shared.open(file)
    }

    // The text with every finding underlined, for the detail view.
    static func highlighted(_ text: String, _ notices: [Notice], accent: Color) -> AttributedString {
        var out = AttributedString(text)
        for n in notices {
            guard let r = Range(n.range, in: text), let lo = AttributedString.Index(r.lowerBound, within: out),
                let hi = AttributedString.Index(r.upperBound, within: out)
            else { continue }
            out[lo..<hi].underlineStyle = .single
            out[lo..<hi].foregroundColor = accent
        }
        return out
    }
}

struct NoticedView: View {
    let item: Item
    let c: Palette
    var onBack: () -> Void
    @State private var notices: [Notice] = []
    @State private var done: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BackRow(title: "From \(item.app ?? "your clipboard"), \(item.ts.formatted(.dateTime.hour().minute()))", c: c, onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(Noticer.highlighted(String(item.body.prefix(1200)), notices, accent: c.warm))
                        .font(.system(size: 15)).foregroundStyle(c.text).lineSpacing(4).textSelection(.enabled)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(c.paper))
                    Label(
                        notices.isEmpty
                            ? "Nothing to act on in this one."
                            : "Sill noticed \(notices.count) \(notices.count == 1 ? "thing" : "things") you can act on",
                        systemImage: "sparkles"
                    )
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(c.text)
                    ForEach(notices) { n in row(n) }
                }
            }
        }
        .task(id: item.id) { notices = Noticer.find(in: item.body) }
    }

    private func row(_ n: Notice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: n.icon).font(.system(size: 14)).foregroundStyle(c.accent).frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(c.accent.opacity(0.13)))
            VStack(alignment: .leading, spacing: 2) {
                Text(n.title).font(.system(size: 13, weight: .medium)).foregroundStyle(c.text).lineLimit(1)
                Text(n.hint).font(.system(size: 11.5)).foregroundStyle(c.soft).lineLimit(1)
            }
            Spacer()
            Chip(icon: done.contains(n.id) ? "checkmark" : "arrow.right", title: n.action, primary: n.kind == .event, c: c) {
                Noticer.run(n)
                done.insert(n.id)
            }
        }
        .padding(.horizontal, 12).frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 12).fill(c.raised.opacity(0.6)))
    }
}
