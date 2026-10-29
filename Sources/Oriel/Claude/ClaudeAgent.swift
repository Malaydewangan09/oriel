import AppKit
import SwiftUI

// Hands a stack to the user's own Claude Code as a real background session they open from any terminal.
// It starts in plan mode: Claude investigates and proposes, and changes nothing until the user attaches and approves.
// Secrets are masked before the stack leaves the Mac.
@MainActor
final class ClaudeAgent: ObservableObject {
    static let shared = ClaudeAgent()
    nonisolated static let source = "Claude"

    enum State: Equatable {
        case idle
        case starting
        case running(id: String, status: String)  // status from `claude agents`: busy, idle, done
        case inTerminal  // the folder wasn't trusted yet: started in Terminal instead
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var task = ""
    @Published private(set) var folder: URL?
    private(set) var unseen = false
    private var poll: Timer?

    var name: String { "Oriel: \(task)" }

    func run(task: String, context: String, in folder: URL) {
        poll?.invalidate()
        guard let claude = Self.binary else {
            state = .failed("Claude Code isn't installed. Get it at claude.com/claude-code, then try again.")
            return
        }
        self.task = task
        self.folder = folder
        unseen = false
        state = .starting
        let prompt = Self.prompt(context)
        let name = self.name
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Self.exec(claude, ["--bg", "-n", name, "--permission-mode", "plan", prompt], in: folder)
            DispatchQueue.main.async {
                let agent = ClaudeAgent.shared
                if let id = Self.sessionID(in: out) {
                    agent.state = .running(id: id, status: "busy")
                    agent.watch(id, claude: claude)
                } else if out.contains("not trusted") {
                    // A folder Claude hasn't opened before needs its trust prompt, which only a terminal can show.
                    agent.openTerminal(claude: claude, args: ["--permission-mode", "plan"], prompt: prompt, in: folder)
                    agent.state = .inTerminal
                } else {
                    agent.state = .failed(out.isEmpty ? "Claude Code didn't start. Run `claude` in Terminal once to sign in." : out)
                }
            }
        }
    }

    nonisolated static func prompt(_ context: String) -> String {
        """
        Here is everything I collected for one task, oldest first. Each item says where it came from.

        \(String(context.prefix(100_000)))

        Work out what I'm trying to do with this. It could be a bug, a question to answer, a reply to write, something to review or summarise, or something else.
        Use the files in this folder if they help.
        Start by telling me in two or three sentences what you think the task is and how you'd go about it. Then wait for me before changing or sending anything.
        """
    }

    // Checks the session now and then, and tells the notch when Claude is waiting for the user.
    private func watch(_ id: String, claude: URL) {
        poll = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async {
                let json = Self.exec(claude, ["agents", "--json", "--all"], in: FileManager.default.homeDirectoryForCurrentUser)
                let status = Self.status(of: id, in: json)
                DispatchQueue.main.async { ClaudeAgent.shared.update(id, status) }
            }
        }
    }

    private func update(_ id: String, _ status: String?) {
        guard case .running(let current, let was) = state, current == id else { poll?.invalidate(); return }
        guard let status else { poll?.invalidate(); state = .idle; return }  // stopped or removed from the terminal
        state = .running(id: id, status: status)
        if was == "busy" && status != "busy" {
            unseen = true
            let note = "Claude is ready on \(task)"
            let item = Item(id: -1, kind: .copy, ts: Date(), app: nil, title: note, body: note, path: nil, source: Self.source)
            NotificationCenter.default.post(name: .orielCaught, object: nil, userInfo: ["item": item])
        }
    }

    func seen() { unseen = false }

    func forget() {
        poll?.invalidate()
        state = .idle
        unseen = false
    }

    // Opens the session in the user's terminal, where they carry on with it.
    func attach() {
        guard case .running(let id, _) = state, let claude = Self.binary, let folder else { return }
        openTerminal(claude: claude, args: ["attach", id], in: folder)
    }

    var attachCommand: String? {
        if case .running(let id, _) = state { return "claude attach \(id)" }
        return nil
    }

    // iTerm when it's installed: Terminal.app's default profile can't draw Claude Code's 24-bit colours.
    // A long prompt goes through a file, so the window title stays "claude" instead of the whole task.
    private func openTerminal(claude: URL, args: [String], prompt: String? = nil, in folder: URL) {
        let tmp = FileManager.default.temporaryDirectory, tag = UUID().uuidString.prefix(8)
        let script = tmp.appendingPathComponent("oriel-claude-\(tag).command")
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var lines = ["#!/bin/zsh", "cd \(q(folder.path)) || exit 1", "rm -f \"$0\""]
        var command = ([claude.path] + args).map(q).joined(separator: " ")
        if let prompt {
            let file = tmp.appendingPathComponent("oriel-claude-\(tag).txt")
            guard (try? prompt.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            lines += ["task=$(<\(q(file.path)))", "rm -f \(q(file.path))"]
            command += " \"$task\""
        }
        lines.append("exec \(command)")
        guard (try? (lines.joined(separator: "\n") + "\n").write(to: script, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        if let app = Self.terminal.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) }) {
            NSWorkspace.shared.open([script], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(script)
        }
    }

    // Terminals known to run a script opened with them. Only the installed ones are offered.
    nonisolated static let terminals: [(id: String, name: String)] = [("com.googlecode.iterm2", "iTerm"), ("com.apple.Terminal", "Terminal")]
    nonisolated static var installedTerminals: [(id: String, name: String)] {
        terminals.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }
    // The user's pick, else iTerm when installed, since Terminal's default profile can't draw Claude Code's colours.
    nonisolated static var terminal: (id: String, name: String)? {
        let installed = installedTerminals
        return installed.first { $0.id == UserDefaults.standard.string(forKey: Pref.claudeTerminal) } ?? installed.first
    }

    // MARK: Helpers

    // "backgrounded · b06896a9 · Oriel: api #482" -> "b06896a9"
    nonisolated static func sessionID(in output: String) -> String? {
        guard let r = output.range(of: #"backgrounded · ([0-9a-f]{6,})"#, options: .regularExpression) else { return nil }
        return output[r].components(separatedBy: " · ").last
    }

    nonisolated static func status(of id: String, in json: String) -> String? {
        guard let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
            let s = list.first(where: { $0["id"] as? String == id })
        else { return nil }
        return s["state"] as? String == "done" ? "done" : s["status"] as? String
    }

    nonisolated static func exec(_ tool: URL, _ args: [String], in folder: URL) -> String {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        p.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"]].compactMap { $0 }.joined(separator: ":")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // "acme/api" from a GitHub or GitLab link in the stack.
    nonisolated static func repoName(in items: [Item]) -> String? {
        for item in items {
            guard let r = item.body.range(of: #"(?:github|gitlab)\.com/([\w.-]+/[\w.-]+)"#, options: .regularExpression) else { continue }
            let path = item.body[r].split(separator: "/").dropFirst()
            return path.prefix(2).joined(separator: "/")
        }
        return nil
    }

    // Asks once where a repo lives, then remembers. Suggests a folder with the repo's name in the usual places.
    static func folder(for repo: String) -> URL? {
        var saved = UserDefaults.standard.dictionary(forKey: Pref.claudeFolders) as? [String: String] ?? [:]
        if let path = saved[repo], FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use this folder"
        panel.message = "Which folder should Claude work in for \(repo)? Pick the project's folder, or any folder for a task without code."
        panel.directoryURL = guess(repo)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        saved[repo] = url.path
        UserDefaults.standard.set(saved, forKey: Pref.claudeFolders)
        return url
    }

    private static func guess(_ repo: String) -> URL? {
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        let home = FileManager.default.homeDirectoryForCurrentUser
        for base in ["dev", "Developer", "code", "src", "Projects", "projects", "work", "GitHub", ""] {
            let dir = home.appendingPathComponent(base)
            let direct = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: direct.appendingPathComponent(".git").path) { return direct }
            for sub in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let nested = dir.appendingPathComponent(sub).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: nested.appendingPathComponent(".git").path) { return nested }
            }
        }
        return nil
    }

    // Claude Code isn't on a Mac app's PATH, so look where its installers put it.
    nonisolated static var binary: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let spots = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return spots.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

}
