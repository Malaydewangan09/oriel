import Foundation
import SQLite3

// One local SQLite file: everything Oriel remembers, with full-text search over title and body.
final class Store: @unchecked Sendable {
    static let shared: Store = {
        do { return try Store(path: ProcessInfo.processInfo.environment["ORIEL_DB"]) } catch {
            fatalError("Oriel cannot open its database: \(error)")
        }
    }()

    // Named after the app's working title. Kept so existing history carries over.
    static let folder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
            "Desk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct OpenError: Error, CustomStringConvertible {
        let path: String
        var description: String { "Cannot open the database at '\(path)'." }
    }

    init(path: String? = nil) throws {
        let file = path ?? Self.folder.appendingPathComponent("desk.sqlite").path
        guard sqlite3_open(file, &db) == SQLITE_OK else { throw OpenError(path: file) }
        exec("PRAGMA journal_mode=WAL")
        exec(
            """
            CREATE TABLE IF NOT EXISTS items(id INTEGER PRIMARY KEY, kind TEXT NOT NULL, ts REAL NOT NULL, app TEXT,
              title TEXT NOT NULL, body TEXT NOT NULL, path TEXT, source TEXT, fingerprint TEXT UNIQUE);
            CREATE INDEX IF NOT EXISTS items_ts ON items(ts);
            CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(title, body, content='items', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
            """)
        exec("ALTER TABLE items ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0")
        exec("ALTER TABLE items ADD COLUMN secret TEXT")
        exec("ALTER TABLE items ADD COLUMN expires REAL")
        // Earlier builds kept app usage and meaning vectors. Oriel no longer records either, so they are removed.
        exec("DROP TABLE IF EXISTS spans")
        exec("ALTER TABLE items DROP COLUMN vec")
        // Secrets never enter the search index.
        exec(
            """
            DROP TRIGGER IF EXISTS items_ai;
            CREATE TRIGGER items_ai AFTER INSERT ON items BEGIN
              INSERT INTO items_fts(rowid, title, body) VALUES (new.id, new.title, CASE WHEN new.secret IS NULL THEN new.body ELSE '' END); END;
            CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
              INSERT INTO items_fts(items_fts, rowid, title, body) VALUES ('delete', old.id, old.title, CASE WHEN old.secret IS NULL THEN old.body ELSE '' END); END;
            CREATE TABLE IF NOT EXISTS stacks(id INTEGER PRIMARY KEY, name TEXT NOT NULL, created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS stack_items(stack_id INTEGER NOT NULL, item_id INTEGER NOT NULL, PRIMARY KEY(stack_id, item_id));
            CREATE TRIGGER IF NOT EXISTS items_ad_stack AFTER DELETE ON items BEGIN DELETE FROM stack_items WHERE item_id = old.id; END;
            CREATE TABLE IF NOT EXISTS forgotten(fingerprint TEXT PRIMARY KEY, ts REAL NOT NULL);
            """)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    // Fingerprint makes re-imports and repeated copies idempotent.
    @discardableResult
    func add(
        kind: Kind, ts: Date = Date(), app: String?, title: String, body: String, path: String? = nil, source: String? = nil, fingerprint: String,
        secret: String? = nil
    ) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        if (kind == .download || kind == .screenshot) && wasForgotten(fingerprint) { return nil }
        let expires = secret == nil ? nil : ts.addingTimeInterval(Secrets.lifetime)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(
            db, "INSERT OR IGNORE INTO items(kind, ts, app, title, body, path, source, fingerprint, secret, expires) VALUES(?,?,?,?,?,?,?,?,?,?)", -1,
            &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, kind.rawValue)
        sqlite3_bind_double(stmt, 2, ts.timeIntervalSince1970)
        bind(stmt, 3, app); bind(stmt, 4, title); bind(stmt, 5, body)
        bind(stmt, 6, path); bind(stmt, 7, source); bind(stmt, 8, fingerprint)
        bind(stmt, 9, secret)
        if let expires { sqlite3_bind_double(stmt, 10, expires.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 10) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        // Copying the same text again moves the one row to the top instead of adding another.
        if sqlite3_changes(db) == 0 { return (kind == .copy || kind == .link) && secret == nil ? touch(fingerprint, ts: ts) : nil }
        let item = Item(
            id: sqlite3_last_insert_rowid(db), kind: kind, ts: ts, app: app, title: title, body: body, path: path, source: source, secret: secret,
            expires: expires)
        announce(item)
        return item.id
    }

    // Caller holds the lock.
    private func touch(_ fingerprint: String, ts: Date) -> Int64? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE items SET ts = ? WHERE fingerprint = ? RETURNING id, kind, app, title, body, path, source", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, ts.timeIntervalSince1970)
        bind(stmt, 2, fingerprint)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let s = { (i: Int32) in sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        let item = Item(
            id: sqlite3_column_int64(stmt, 0), kind: Kind(rawValue: s(1) ?? "") ?? .copy, ts: ts, app: s(2), title: s(3) ?? "", body: s(4) ?? "",
            path: s(5), source: s(6))
        announce(item)
        return item.id
    }

    private func announce(_ item: Item) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .orielCaught, object: nil, userInfo: ["item": item]) }
    }

    // Caller holds the lock.
    private func wasForgotten(_ fingerprint: String) -> Bool {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT 1 FROM forgotten WHERE fingerprint = ?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, fingerprint)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // Removes one item from Oriel only. Files on disk stay, and a deleted download or screenshot is not indexed again.
    func delete(_ id: Int64) {
        lock.lock(); defer { lock.unlock() }
        exec(
            """
            INSERT OR IGNORE INTO forgotten(fingerprint, ts) SELECT fingerprint, \(Date().timeIntervalSince1970) FROM items
              WHERE id = \(id) AND kind IN ('download', 'screenshot') AND fingerprint IS NOT NULL;
            DELETE FROM items WHERE id = \(id);
            """)
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(stmt, i, v, -1, transient) } else { sqlite3_bind_null(stmt, i) }
    }

    // Filters narrow the set, words match the full-text index. Newest first.
    func search(_ q: Query, limit: Int = 60) -> [Item] {
        lock.lock(); defer { lock.unlock() }
        var clauses: [String] = [], binds: [Any] = []
        var sql = "SELECT i.id, i.kind, i.ts, i.app, i.title, i.body, i.path, i.source, i.secret, i.expires FROM items i"
        if let fts = q.ftsExpression {
            sql += " JOIN items_fts f ON f.rowid = i.id"
            clauses.append("items_fts MATCH ?"); binds.append(fts)
        }
        if !q.kinds.isEmpty {
            clauses.append("i.kind IN (\(q.kinds.map { _ in "?" }.joined(separator: ",")))")
            binds.append(contentsOf: q.kinds.map(\.rawValue))
        }
        if let from = q.from { clauses.append("i.ts >= ?"); binds.append(from.timeIntervalSince1970) }
        if let to = q.to { clauses.append("i.ts < ?"); binds.append(to.timeIntervalSince1970) }
        if let app = q.app { clauses.append("(i.app LIKE ? OR i.source LIKE ?)"); binds.append("%\(app)%"); binds.append("%\(app)%") }
        if q.pinnedOnly { clauses.append("i.pinned = 1") }
        if let ids = q.ids { clauses.append("i.id IN (\(ids.map(String.init).joined(separator: ",")))") }
        clauses.append("(i.expires IS NULL OR i.expires > \(Date().timeIntervalSince1970))")
        sql += " WHERE " + clauses.joined(separator: " AND ") + " ORDER BY i.ts DESC LIMIT \(limit)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (n, v) in binds.enumerated() {
            if let d = v as? Double { sqlite3_bind_double(stmt, Int32(n + 1), d) } else { bind(stmt, Int32(n + 1), "\(v)") }
        }
        var out: [Item] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = { (i: Int32) in sqlite3_column_text(stmt, i).map { String(cString: $0) } }
            out.append(
                Item(
                    id: sqlite3_column_int64(stmt, 0), kind: Kind(rawValue: s(1) ?? "") ?? .copy,
                    ts: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)), app: s(3), title: s(4) ?? "", body: s(5) ?? "", path: s(6),
                    source: s(7),
                    secret: s(8),
                    expires: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))))
        }
        return out
    }

    // Removes expired secrets and anything older than the chosen history length. Pinned items always stay.
    func purge(keepDays: Int) {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        exec("DELETE FROM items WHERE expires IS NOT NULL AND expires <= \(now)")
        exec("DELETE FROM forgotten WHERE ts < \(now - 30 * 86_400)")  // the indexer only looks back 14 days
        if keepDays > 0 { exec("DELETE FROM items WHERE pinned = 0 AND ts < \(now - Double(keepDays) * 86_400)") }
    }

    func forgetEverything() {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM items; DELETE FROM stacks; DELETE FROM stack_items; INSERT INTO items_fts(items_fts) VALUES('rebuild'); VACUUM;")
    }

    func setPinned(_ id: Int64, _ pinned: Bool) {
        lock.lock(); defer { lock.unlock() }
        exec("UPDATE items SET pinned = \(pinned ? 1 : 0) WHERE id = \(id)")
    }

    func pinnedIDs() -> Set<Int64> {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id FROM items WHERE pinned = 1", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var out = Set<Int64>()
        while sqlite3_step(stmt) == SQLITE_ROW { out.insert(sqlite3_column_int64(stmt, 0)) }
        return out
    }

    // Stacks the user made by hand. Auto stacks are worked out from the items and never stored.
    @discardableResult
    func createStack(_ name: String) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO stacks(name, created) VALUES(?, ?)", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, name)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    func setInStack(_ stack: Int64, item: Int64, _ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        exec(
            on
                ? "INSERT OR IGNORE INTO stack_items(stack_id, item_id) VALUES(\(stack), \(item))"
                : "DELETE FROM stack_items WHERE stack_id = \(stack) AND item_id = \(item)")
    }

    func deleteStack(_ id: Int64) {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM stack_items WHERE stack_id = \(id); DELETE FROM stacks WHERE id = \(id)")
    }

    func manualStacks() -> [(id: Int64, name: String, items: [Int64])] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(
            db, "SELECT s.id, s.name, si.item_id FROM stacks s LEFT JOIN stack_items si ON si.stack_id = s.id ORDER BY s.created DESC", -1, &stmt, nil
        )
        defer { sqlite3_finalize(stmt) }
        var out: [(id: Int64, name: String, items: [Int64])] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            if out.last?.id != id { out.append((id, String(cString: sqlite3_column_text(stmt, 1)), [])) }
            if sqlite3_column_type(stmt, 2) != SQLITE_NULL { out[out.count - 1].items.append(sqlite3_column_int64(stmt, 2)) }
        }
        return out
    }

    // Names Oriel has actually seen: apps you copied from, and sites files came from.
    func knownSources() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(
            db, "SELECT DISTINCT app FROM items WHERE app IS NOT NULL UNION SELECT DISTINCT source FROM items WHERE source IS NOT NULL", -1, &stmt,
            nil)
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let t = sqlite3_column_text(stmt, 0) { out.append(String(cString: t)) } }
        return out
    }
}
