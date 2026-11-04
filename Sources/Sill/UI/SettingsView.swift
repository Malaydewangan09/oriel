import SwiftUI

struct SettingsView: View {
    @AppStorage(Pref.keepDays) private var keepDays = 30
    @AppStorage(Pref.peek) private var peek = true
    @AppStorage(Pref.secretGuard) private var secretGuard = true
    @AppStorage(Pref.autoCleanLinks) private var autoClean = false
    @AppStorage(Pref.excludedApps) private var excluded = ""
    @AppStorage(Pref.appearance) private var appearance: Appearance = .auto
    @AppStorage(Pref.design) private var design: Design = .glass
    @AppStorage(Pref.quickPaste) private var quickPaste = true
    @AppStorage(Pref.claudeTerminal) private var claudeTerminal = ClaudeAgent.terminal?.id ?? "com.apple.Terminal"
    @State private var newApp = ""
    @State private var confirmForget = false
    @State private var forgotten = false

    private var apps: [String] { excluded.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    var body: some View {
        Form {
            Section {
                Picker("Keep history for", selection: $keepDays) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("Forever").tag(0)
                }
                Picker("Appearance", selection: $appearance) { ForEach(Appearance.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Picker("Design", selection: $design) { ForEach(Design.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Toggle("Show a peek in the notch when something is saved", isOn: $peek)
                Toggle("Quick paste with ⌥V", isOn: $quickPaste)
            } footer: {
                Text("Pinned items are kept no matter what. Quick paste pastes for you once Sill has Accessibility access. Without it, it copies.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Secret guard", isOn: $secretGuard)
                Text("API keys, tokens, private keys and card numbers are shown masked, never searchable, and forgotten after 2 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Remove trackers from links I copy", isOn: $autoClean)
                Text("Strips utm_, fbclid, gclid and similar from links as you copy them.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Open Claude sessions in", selection: $claudeTerminal) {
                    ForEach(ClaudeAgent.installedTerminals, id: \.id) { Text($0.name).tag($0.id) }
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("Hand to Claude starts a session in your own Claude Code. It opens here when you attach to it.").font(.caption).foregroundStyle(
                    .secondary)
            }

            Section("Never save from these apps") {
                ForEach(apps, id: \.self) { app in
                    HStack {
                        Text(app)
                        Spacer()
                        Button {
                            excluded = apps.filter { $0 != app }.joined(separator: ",")
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("App name, like Slack", text: $newApp).onSubmit(add)
                    Button("Add", action: add).disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Forget everything")
                        Text(forgotten ? "Done. Sill starts fresh." : "Deletes all saved copies, files, screenshots and history from this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget…", role: .destructive) { confirmForget = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .confirmationDialog("Forget everything Sill has saved?", isPresented: $confirmForget) {
            Button("Forget everything", role: .destructive) {
                Store.shared.forgetEverything()
                forgotten = true
            }
        } message: {
            Text("This can't be undone. Files in your Downloads and Desktop are not touched.")
        }
    }

    private func add() {
        let name = newApp.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !apps.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        excluded = (apps + [name]).joined(separator: ",")
        newApp = ""
    }
}
