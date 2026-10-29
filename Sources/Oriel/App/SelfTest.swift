import AppKit

// `Oriel --selftest`: checks the pure logic on known inputs and exits non-zero on any failure.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool) { print(ok ? "ok   " : "FAIL ", name); if !ok { failures += 1 } }
        check("GitHub token", Secrets.kind(of: "token: ghp_" + String(repeating: "a1B2", count: 9)) == "GitHub token")
        check("AWS key", Secrets.kind(of: "AKIAIOSFODNN7EXAMPLE") == "AWS key")
        check("OpenAI key", Secrets.kind(of: "sk-proj-abcdefghijklmnopqrstuvwx12") == "OpenAI key")
        check("Anthropic key", Secrets.kind(of: "sk-ant-api03-abcdefghijklmnopqrstuvwxyz") == "Anthropic key")
        check("Private key", Secrets.kind(of: "-----BEGIN OPENSSH PRIVATE KEY-----\nabc") == "Private key")
        check("Card number (valid Luhn)", Secrets.kind(of: "4111 1111 1111 1111") == "Card number")
        check("Not a card (bad Luhn)", Secrets.kind(of: "4111 1111 1111 1112") == nil)
        check("Plain text is not a secret", Secrets.kind(of: "meeting at 4pm about the roadmap") == nil)
        check("Phone number is not a secret", Secrets.kind(of: "+91 98765 43210") == nil)
        check("Clean link drops utm and fbclid", LinkCleaner.clean("https://ex.com/a?utm_source=x&id=7&fbclid=y") == "https://ex.com/a?id=7")
        check("Clean link leaves clean links alone", LinkCleaner.clean("https://ex.com/a?id=7") == nil)
        check("Pretty JSON", Transform.jsonPretty.apply("{\"b\":1,\"a\":[1,2]}")?.contains("\n") == true)
        check("Not JSON gets no JSON option", !Transform.available(for: "hello world").contains(.jsonPretty))
        check("A bare number gets no JSON option", !Transform.available(for: "193").contains(.jsonPretty))
        check(
            "Claude: the session id comes from the start output",
            ClaudeAgent.sessionID(in: "backgrounded · b06896a9 · Oriel: api #482\n  claude agents") == "b06896a9")
        check(
            "Claude: session status from the agents list",
            ClaudeAgent.status(of: "b06896a9", in: #"[{"id":"b06896a9","status":"idle","state":"running"},{"id":"x","status":"busy"}]"#) == "idle"
                && ClaudeAgent.status(of: "gone", in: "[]") == nil)
        check(
            "Claude: the repo comes from a PR link",
            ClaudeAgent.repoName(in: [
                Item(id: 1, kind: .link, ts: Date(), app: nil, title: "", body: "https://github.com/acme/api/pull/482", path: nil, source: nil)
            ]) == "acme/api")
        check(
            "Text for AI hides tokens and link passwords",
            {
                let r = Secrets.redact(
                    "token: ghp_" + String(repeating: "a1B2", count: 9) + "\nDB_URL=postgres://admin:" + "Hx92kLq7" + "@db.acme.dev:5432/app")
                return !r.contains("ghp_a1B2") && !r.contains("Hx92kLq7") && r.contains("postgres://admin:[password hidden]@db.acme.dev")
            }())
        check("Base64 decode", Transform.base64.apply("aGVsbG8gd29ybGQ=") == "hello world")
        check(
            "Mark up draws on the full-size image",
            {
                guard
                    let ctx = CGContext(
                        data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
                guard let white = ctx.makeImage(),
                    let out = Markup.render(
                        white, [Mark(tool: .box, a: CGPoint(x: 0.1, y: 0.1), b: CGPoint(x: 0.9, y: 0.9), color: .red)], pixel: nil),
                    let data = out.dataProvider?.data as Data?
                else { return false }
                // The box's left edge sits at x = 20. The pixel there should be red, the centre still white.
                func px(_ x: Int, _ y: Int) -> (UInt8, UInt8) { let i = y * out.bytesPerRow + x * 4; return (data[i], data[i + 1]) }
                let edge = px(20, 50), centre = px(100, 50)
                return edge.0 > 150 && edge.1 < 120 && centre.0 > 240 && centre.1 > 240
            }())
        check(
            "Join PDF lines",
            Transform.joined.apply("The retry worker gives up after three exam-\nples of failure and\nlogs it.\n\nNext para")
                == "The retry worker gives up after three examples of failure and logs it.\n\nNext para")
        check("Remove duplicate lines", Transform.deduped.apply("a\nb\na\nc\nb") == "a\nb\nc")
        check("Spreadsheet to CSV", Transform.csv.apply("Name\tCity\nAlex\tPune, MH") == "Name,City\nAlex,\"Pune, MH\"")
        check("Markdown table to CSV", Transform.csv.apply("| a | b |\n|---|---|\n| 1 | 2 |") == "a,b\n1,2")
        check("Plain prose is not a table", Transform.csv.apply("hello world\nsecond line") == nil)
        check(
            "Copy for AI fences code and skips secrets",
            ShelfModel.aiBlock(
                Item(id: 1, kind: .copy, ts: Date(), app: "Xcode", title: "", body: "func retry() {\n  try send()\n}", path: nil, source: nil))?
                .contains("```") == true
                && ShelfModel.aiBlock(
                    Item(id: 2, kind: .copy, ts: Date(), app: "Terminal", title: "", body: "ghp_x", path: nil, source: nil, secret: "GitHub token"))
                    == nil
        )
        check("Extract links", Transform.links.apply("see https://a.com and https://b.org/x") == "https://a.com\nhttps://b.org/x")
        check("Extract emails", Transform.emails.apply("mail me at a@b.com or c@d.io") == "a@b.com\nc@d.io")
        check("Code detected", Look.looksLikeCode("func retry() {\n  return x\n}"))
        check("Prose is not code", !Look.looksLikeCode("Can you review the retry logic before 4pm?"))
        let q = Query.parse("links from slack 3 days ago", sources: ["slack"])
        check("Query: kind, app and relative date", q.kinds == [.link] && q.app == "slack" && q.from != nil)

        // Noticed: a fixed "now" so the date check doesn't drift.
        let now = ISO8601DateFormatter().date(from: "2026-10-22T10:00:00Z")!
        let mail =
            "Your parcel 1Z999AA10123456784 arrives Thursday. Client sync moved to Oct 23, 2026 at 4:00 pm, join at https://meet.google.com/abc-defg-hij. Call +91 98765 43210 if you're out."
        let kinds = Set(Noticer.find(in: mail, now: now).map(\.kind))
        check("Noticed: parcel, meeting, event, phone", kinds.isSuperset(of: [.parcel, .meeting, .event, .phone]))
        check("Noticed: event carries the meeting link", Noticer.find(in: mail, now: now).first { $0.kind == .event }?.url?.host == "meet.google.com")
        check("Noticed: past dates are skipped", !Noticer.find(in: "We met on Jan 3, 2020 at 2pm.", now: now).contains { $0.kind == .event })
        check("Noticed: plain prose finds nothing", Noticer.find(in: "Looks good to me, ship it.", now: now).isEmpty)

        // Stacks
        func item(_ id: Int64, _ body: String, kind: Kind = .copy) -> Item {
            Item(id: id, kind: kind, ts: now, app: nil, title: "", body: body, path: nil, source: nil)
        }
        let stacks = Stacks.auto(from: [
            item(1, "https://github.com/acme/api/pull/482", kind: .link), item(2, "Error in #482 retry loop"), item(3, "ENG-142 is blocked"),
            item(4, "ENG-142 notes"), item(5, "#E3735C"), item(6, "UTF-8 encoding"), item(7, "UTF-8 again"),
        ])
        check("Stacks: PR link and #482 group, named after the repo", stacks.contains { $0.name == "api #482" && $0.itemIDs == [1, 2] })
        check("Stacks: ticket keys group", stacks.contains { $0.name == "ENG-142" && $0.itemIDs == [3, 4] })
        check("Stacks: UTF-8 is not a ticket, a colour is not an issue", !stacks.contains { $0.name.hasPrefix("UTF") || $0.itemIDs.contains(5) })

        // Share safely
        let found = ShareSafe.sensitive(
            in: "DB_URL=postgres://admin:" + "Hx92kL" + "@10.0.3.14 owner: alex@acme.io token: ghp_" + String(repeating: "a1B2", count: 9))
        check(
            "Share safely: password in link, email, token",
            Set(found.map(\.0)).isSuperset(of: ["Password in a link", "Email address", "GitHub token"]))
        check(
            "Share safely: an error line is left alone", ShareSafe.sensitive(in: "Error: connect ECONNRESET at TCPConnectWrap.afterConnect").isEmpty)

        // Store: one row per text, and deleted files stay deleted. A throwaway database, never the real one.
        let dbPath = NSTemporaryDirectory() + "oriel-selftest-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        if let store = try? Store(path: dbPath) {
            let a = store.add(kind: .copy, ts: now, app: "iTerm2", title: "pen", body: "Pen tool", fingerprint: copyFingerprint("Pen tool"))
            let b = store.add(
                kind: .copy, ts: now.addingTimeInterval(90), app: "Oriel", title: "pen", body: "Pen tool", fingerprint: copyFingerprint("Pen tool"))
            let rows = store.search(Query(), limit: 10)
            check("Copying the same text again keeps one row", a != nil && a == b && rows.count == 1)
            check(
                "The repeat moves it to the top and keeps where it came from",
                rows.first?.ts == now.addingTimeInterval(90) && rows.first?.app == "iTerm2")
            let shot = store.add(
                kind: .screenshot, ts: now, app: nil, title: "Screenshot 1.png", body: "", path: "/tmp/s1.png", fingerprint: "shot-1")
            store.delete(shot ?? -1)
            check(
                "A deleted screenshot is not indexed again",
                store.add(kind: .screenshot, ts: now, app: nil, title: "Screenshot 1.png", body: "", path: "/tmp/s1.png", fingerprint: "shot-1")
                    == nil)
            store.delete(a ?? -1)
            check(
                "A deleted copy is saved again when copied again",
                store.add(kind: .copy, ts: now, app: nil, title: "pen", body: "Pen tool", fingerprint: copyFingerprint("Pen tool")) != nil)
        } else {
            check("Store opens a throwaway database", false)
        }

        // Labels
        let dropped = Item(
            id: 8, kind: .download, ts: now, app: "Oriel", title: "photo.png", body: "", path: "/tmp/photo.png", source: Item.notchSource)
        check("A notch drop says Notch, not the full phrase", dropped.origin == "Notch")
        check("An image row names the file, not 'Image'", dropped.rowLine == "photo")
        check(
            "System helpers are not named as the source",
            Item(id: 9, kind: .copy, ts: now, app: "UserNotificationCenter", title: "", body: "x", path: nil, source: nil).origin == nil)
        print(failures == 0 ? "all passed" : "\(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
