import SwiftUI

// The row of actions in the side pane: what Oriel found in it, its main actions, stacks and everything else under More.
struct ActionBar: View {
    @ObservedObject var model: ShelfModel
    let item: Item
    let c: Palette
    @Binding var translating: String?
    @State private var privateCount: [Int64: Int] = [:]
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        let actions = model.actions(for: item, translate: { translating = $0 })
        let notices = item.isText ? Noticer.find(in: item.body).count : 0
        // Buttons shown in the bar. The rest, like Look closer and AirDrop, live under More.
        let inline = item.isImage ? 0 : notices > 0 ? 1 : 2
        return HStack(spacing: 8) {
            // Only news worth reading. It gives way first when space is tight.
            if item.isImage, let n = privateCount[item.id], n > 0 {
                Text("· \(n) private \(n == 1 ? "thing" : "things") to hide").font(.system(size: 12)).foregroundStyle(c.warm).lineLimit(1)
                    .layoutPriority(-1)
            }
            if notices > 0 {
                Text("· \(notices) \(notices == 1 ? "thing" : "things") to act on").font(.system(size: 12)).foregroundStyle(c.warm).lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if item.isImage {
                Chip(icon: "eye.slash", title: "Share safely", primary: true, c: c) { model.openDetail() }.fixedSize()
                Chip(icon: "pencil.tip", title: "Mark up", c: c) { withAnimation(.spring(duration: 0.3)) { model.detail = .markup(item.id) } }
                    .fixedSize()
            }
            if notices > 0 { Chip(icon: "sparkles", title: "Act on it", primary: true, c: c) { model.openDetail() }.fixedSize() }
            ForEach(actions.prefix(inline)) { a in Chip(icon: a.icon, title: short(a.title), c: c, action: a.run).fixedSize() }
            stackMenu
            if actions.count > inline || !CopyAsMenu.options(for: item).isEmpty {
                Menu {
                    ForEach(actions.dropFirst(inline)) { a in Button(action: a.run) { Label(a.title, systemImage: a.icon) } }
                    CopyAsMenu(model: model, item: item)
                } label: {
                    ChipLabel(icon: "ellipsis", title: "More", c: c)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
        }
        .task(id: item.id) {
            guard item.isImage, privateCount[item.id] == nil else { return }
            if let scan = await ShareSafe.scan(item) { privateCount[item.id] = scan.findings.count }
        }
    }

    private func short(_ title: String) -> String {
        title.replacingOccurrences(of: " (trackers removed)", with: "")
    }

    private var stackMenu: some View {
        let manual = model.stacks.filter { !$0.auto }
        return Menu {
            if !manual.isEmpty {
                // Toggles give the native checkmark on stacks that already hold this item.
                Section("Add to stack") {
                    ForEach(manual) { s in
                        Toggle(isOn: Binding(get: { s.itemIDs.contains(item.id) }, set: { _ in model.toggle(item, in: s) })) {
                            Label(s.name, systemImage: "square.stack")
                        }
                    }
                }
                Divider()
            }
            Button {
                newName = ""; naming = true
            } label: {
                Label("New stack…", systemImage: "plus")
            }
        } label: {
            ChipLabel(icon: "square.stack", title: "Stack", c: c)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .popover(isPresented: $naming, arrowEdge: .top) {
            HStack {
                TextField("Name, like Retry fix", text: $newName).textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit {
                        model.newStack(newName, with: item); naming = false
                    }
                Button("Add") {
                    model.newStack(newName, with: item); naming = false
                }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }
}

// "Copy as": conversions that would change this text, like joined PDF lines or a table as CSV.
struct CopyAsMenu: View {
    @ObservedObject var model: ShelfModel
    let item: Item

    static func options(for item: Item) -> [Transform] {
        item.secret == nil && item.path == nil ? Transform.available(for: item.body) : []
    }

    var body: some View {
        let options = Self.options(for: item)
        if !options.isEmpty {
            Menu("Copy as") {
                ForEach(options) { t in
                    Button(t.rawValue) {
                        if let out = t.apply(item.body) { model.copy(out, for: item, note: "Copied as \(t.rawValue.lowercased())") }
                    }
                }
            }
        }
    }
}
