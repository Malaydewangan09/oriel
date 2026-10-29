import SwiftUI

// The session in the shelf: where it runs and how to open it from a terminal.
struct ClaudeView: View {
    @ObservedObject private var agent = ClaudeAgent.shared
    let c: Palette
    var onBack: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BackRow(title: "Claude · \(agent.task)" + (agent.folder.map { " · \($0.lastPathComponent)" } ?? ""), c: c, onBack: onBack)
            switch agent.state {
            case .idle:
                Text("Open a stack and click Hand to Claude.").font(.system(size: 13)).foregroundStyle(c.soft)
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small); Text("Starting a Claude session…").font(.system(size: 13)).foregroundStyle(c.text)
                }
            case .running(_, let status):
                HStack(spacing: 8) {
                    if status == "busy" {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(c.accent)
                    }
                    Text(status == "busy" ? "Claude is looking into it." : "Claude has a plan and is waiting for you.").font(
                        .system(size: 14, weight: .semibold)
                    ).foregroundStyle(c.text)
                }
                Text("It runs in your own Claude Code, in plan mode: it proposes, and changes nothing until you approve in the terminal.")
                    .font(.system(size: 12.5)).foregroundStyle(c.soft)
                if let cmd = agent.attachCommand {
                    Text(cmd).font(.system(size: 13, design: .monospaced)).foregroundStyle(c.text).textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 8).fill(c.paper))
                    HStack(spacing: 8) {
                        Chip(icon: "terminal", title: "Open in \(ClaudeAgent.terminal?.name ?? "Terminal")", primary: true, c: c) { agent.attach() }
                            .fixedSize()
                        Chip(icon: copied ? "checkmark" : "doc.on.doc", title: copied ? "Copied" : "Copy command", c: c) {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string);
                            NSPasteboard.general.markOwn(); copied = true
                        }.fixedSize()
                        Spacer()
                    }
                    Text("`claude agents` lists it from any terminal.").font(.system(size: 11.5)).foregroundStyle(c.soft)
                }
            case .inTerminal:
                Text("Claude opened in your terminal. It's the first time Claude works in this folder, so it asks you to trust it there first.")
                    .font(.system(size: 13)).foregroundStyle(c.text)
            case .failed(let message):
                Text(message).font(.system(size: 13)).foregroundStyle(c.text).textSelection(.enabled)
                Chip(icon: "xmark", title: "Close", c: c) {
                    agent.forget(); onBack()
                }.fixedSize()
            }
        }
        .onAppear { agent.seen() }
    }
}
