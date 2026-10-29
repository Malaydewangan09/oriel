import AppKit
import SwiftUI

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    var width: CGFloat = 1300
    var onClose: () -> Void
    @FocusState private var searching: Bool
    @AppStorage(Pref.appearance) private var appearance: Appearance = .auto
    @AppStorage(Pref.design) private var design: Design = .glass
    @Environment(\.colorScheme) private var scheme
    @State private var translating: String?
    @State private var picked = false  // the action bar and highlight wait until you choose a card
    private var glass: Bool { design == .glass }
    private var c: Palette { .make(design, dark: appearance.isDark(scheme)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 18) {
                rail.frame(width: 180)
                VStack(alignment: .leading, spacing: 10) {
                    switch model.detail {
                    case .noticed(let id): if let item = model.items.first(where: { $0.id == id }) { NoticedView(item: item, c: c, onBack: back) }
                    case .shareSafe(let id):
                        if let item = model.items.first(where: { $0.id == id }) { ShareSafeView(item: item, c: c, onBack: back, onDone: model.flash) }
                    case .markup(let id):
                        if let item = model.items.first(where: { $0.id == id }) { MarkupView(item: item, c: c, onBack: back, onDone: model.flash) }
                    case .claude: ClaudeView(c: c, onBack: back)
                    case nil:
                        searchRow
                        if model.items.isEmpty {
                            empty
                        } else if listMode {
                            listAndPreview
                        } else {
                            // A chosen card opens beside the grid, the same pane the list uses, so nothing leaves Oriel.
                            HStack(alignment: .top, spacing: 14) {
                                grid
                                if picked, let item = model.current { sidePane(item, width: paneWidth) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 18)
        .onAppear {
            model.refreshStacks(); model.reload(); model.selected = 0; picked = false; searching = true
        }
        .modifier(TranslateSheet(text: $translating))
    }

    // Panel width minus side padding, rail, the gap after it and the grid's own inset.
    private var tileWidth: CGFloat {
        ((cardsWidth - 12 * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
    }

    private var gridWidth: CGFloat { width - 44 - 180 - 18 - 8 }
    private let paneWidth: CGFloat = 400
    // The cards make room while the side pane is open.
    private var cardsWidth: CGFloat { picked && !listMode ? gridWidth - paneWidth - 14 : gridWidth }
    private var columns: Int { max(1, Int((cardsWidth + 12) / (Flow.minTile + 12))) }

    private func back() { withAnimation(.spring(duration: 0.3)) { model.detail = nil }; searching = true }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                OrielMark().frame(width: 17, height: 17).keyframeAnimator(initialValue: 1.0, trigger: model.caught) { v, k in
                    v.scaleEffect(k)
                } keyframes: { _ in
                    SpringKeyframe(1.3, duration: 0.14); SpringKeyframe(1.0, duration: 0.35)
                }
                Text("Oriel").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(c.text).frame(width: 180, alignment: .leading)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(c.soft)
                TextField("Search, like \"links from slack yesterday\"", text: $model.text)
                    .textFieldStyle(.plain).focused($searching).foregroundStyle(c.text)
                    .onKeyPress(.escape) {
                        if model.detail != nil { back() } else if picked && !listMode { picked = false } else { onClose() }; return .handled
                    }
                    .onKeyPress(.leftArrow) {
                        step(-1); return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        step(1); return .handled
                    }
                    .onKeyPress(.upArrow) {
                        step(listMode ? -1 : -columns); return .handled
                    }
                    .onKeyPress(.downArrow) {
                        step(listMode ? 1 : columns); return .handled
                    }
                    .onSubmit { if let item = model.current { model.use(item) } }
                if !model.text.isEmpty {
                    Button {
                        model.text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(c.soft)
                    }.buttonStyle(.plain)
                }
            }
            .font(.system(size: 14)).padding(.horizontal, 14).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: glass ? 19 : 11).fill(c.field))
            .overlay(RoundedRectangle(cornerRadius: glass ? 19 : 11).stroke(c.rim, lineWidth: glass ? 0.9 : 1))
            layoutToggle
            Menu {
                LookPickers()
                Divider()
                Section("Shortcuts") {
                    Text("Click a card, or Return: copy it")
                    Text("Arrows: move between cards")
                    Text("⌘Y: look closer")
                    Text("⌘Return: more for this card")
                    Text("Drag a card: drop it into any app")
                }
                Divider()
                Button("Settings…") { NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil) }
            } label: {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(c.soft)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Design and appearance")
        }
    }

    // Only shows up while searching: what the search understood. Kinds live in the sidebar.
    private var searchRow: some View {
        HStack(spacing: 6) {
            if !model.query.chips.isEmpty || !model.query.words.isEmpty {
                Text("Looking for").foregroundStyle(c.soft)
                ForEach(model.query.chips, id: \.self) {
                    Text($0).fontWeight(.semibold).padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(c.accent.opacity(0.16)))
                        .foregroundStyle(c.accent)
                }
                if !model.query.words.isEmpty { Text("\"\(model.query.words.joined(separator: " "))\"").foregroundStyle(c.soft) }
            } else if case .stack(let id) = model.scope, let stack = model.stacks.first(where: { $0.id == id }) {
                Text(stack.name).fontWeight(.semibold).foregroundStyle(c.text)
                Text("\(model.items.count) \(model.items.count == 1 ? "item" : "items")").foregroundStyle(c.soft)
                Chip(icon: "sparkles", title: "Copy for AI", primary: true, c: c) { model.copyForAI() }.fixedSize().padding(.leading, 10)
                    .help("Copies the whole stack as one message, each item labelled, ready to paste into Claude or ChatGPT")
                Chip(
                    icon: model.isCollecting(stack) ? "record.circle.fill" : "tray.and.arrow.down",
                    title: model.isCollecting(stack) ? "Collecting" : "Collect here", c: c
                ) {
                    model.isCollecting(stack) ? model.stopCollecting() : model.collect(into: stack)
                }.fixedSize()
                    .help(
                        model.isCollecting(stack)
                            ? "Everything you copy goes into this stack. Click to stop."
                            : "Everything you copy next goes into this stack, even if it doesn't match.")
                Chip(icon: "wand.and.stars", title: "Hand to Claude", c: c) { model.handToClaude() }.fixedSize()
                    .help(
                        "Starts a Claude Code session on this task in its code folder, in plan mode. Open it from your terminal with claude attach.")
            }
            Spacer()
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill").fontWeight(.semibold).foregroundStyle(c.accent).transition(.opacity)
            }
        }
        .font(.system(size: 11.5))
    }

    private func step(_ delta: Int) {
        if picked || listMode { model.move(delta) } else { picked = true }
    }

    // Like Finder, each view remembers list or cards. Pictures start as cards, everything else as rows.
    @AppStorage("layouts") private var layouts = ""  // "Text=list,Screenshots=grid,…"
    private var layoutKey: String { model.scope == .tab ? model.tab.rawValue : "Other" }
    private var listMode: Bool {
        let saved = layouts.split(separator: ",").first { $0.hasPrefix(layoutKey + "=") }.map { String($0.dropFirst(layoutKey.count + 1)) }
        if let saved { return saved == "list" }
        return !(model.scope == .tab && (model.tab == .screenshots || model.tab == .colors))
    }
    private func setLayout(list: Bool) {
        var parts = layouts.split(separator: ",").map(String.init).filter { !$0.hasPrefix(layoutKey + "=") }
        parts.append("\(layoutKey)=\(list ? "list" : "grid")")
        layouts = parts.joined(separator: ",")
        picked = false
    }

    private var layoutToggle: some View {
        HStack(spacing: 2) {
            ForEach([true, false], id: \.self) { list in
                Button {
                    setLayout(list: list)
                } label: {
                    Image(systemName: list ? "list.bullet" : "square.grid.2x2").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(listMode == list ? c.text : c.soft)
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(listMode == list ? c.field : .clear))
                }
                .buttonStyle(.plain)
                .help(list ? "Show as a list" : "Show as cards")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(c.line, lineWidth: 1))
    }

    private let listWidth: CGFloat = 340

    private var listAndPreview: some View {
        HStack(alignment: .top, spacing: 14) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.sections, id: \.0) { label, group in
                            Text(label.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(c.soft)
                                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                            ForEach(group) { item in row(item).id(item.id) }
                        }
                    }
                }
                .onChange(of: model.selected) { _, _ in
                    if let item = model.current { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(item.id) } }
                }
            }
            .frame(width: listWidth)
            if let item = model.current { sidePane(item, width: gridWidth + 8 - listWidth - 14) }
        }
    }

    private func sidePane(_ item: Item, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PreviewPane(item: item, c: c)
            ActionBar(model: model, item: item, c: c, translating: $translating)
        }
        .padding(14)
        // Exact width: a large screenshot must never widen the panel and shove the layout sideways.
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: glass ? 20 : 14, style: .continuous).fill(c.raised.opacity(0.7)))
        .overlay(alignment: .topTrailing) {
            if !listMode {
                Button {
                    picked = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(c.soft).frame(width: 22, height: 22)
                        .background(Circle().fill(c.field))
                }
                .buttonStyle(.plain).help("Close (Esc)").padding(10)
            }
        }
    }

    private func row(_ item: Item) -> some View {
        let index = model.items.firstIndex(of: item) ?? 0
        return ListRow(item: item, selected: index == model.selected, copied: model.copiedID == item.id, c: c) { model.copyPrimary(item) }
            .modifier(SwipeToDelete { model.delete(item) })
            // One tap handler reading the click count: a count-2 gesture would hold every single click for the double-click interval.
            .onTapGesture {
                model.selected = index
                if NSApp.currentEvent?.clickCount == 2 { model.use(item) }
            }
            .onDrag { ShelfModel.provider(for: item) }
            .contextMenu {
                ForEach(model.actions(for: item, translate: { translating = $0 })) { a in
                    Button(action: a.run) { Label(a.title, systemImage: a.icon) }
                }
                CopyAsMenu(model: model, item: item)
                deleteButton(item)
            }
    }

    @ViewBuilder private func deleteButton(_ item: Item) -> some View {
        Divider()
        Button(role: .destructive) {
            model.delete(item)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: Rail

    private var rail: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                railRow("sun.max.fill", "Today", tint: c.warm, on: model.scope == .tab && model.tab == .today && model.text.isEmpty) { pick(.today) }
                railRow(
                    "pin.fill", "Pinned", count: model.pinned.isEmpty ? nil : "\(model.pinned.count)", tint: .orange,
                    on: model.scope == .tab && model.tab == .pinned
                ) { pick(.pinned) }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let s = model.secretsLeft
                    if s.count > 0 {
                        railRow(
                            "lock.fill", "Secrets", count: "\(s.count) · \(s.soonest / 60):\(String(format: "%02d", s.soonest % 60))", tint: .orange,
                            on: model.scope == .secrets
                        ) {
                            picked = false; model.show(.secrets)
                        }
                    }
                }
                section("Kinds")
                railRow("text.alignleft", "Text", tint: .gray, on: isTab(.text)) { pick(.text) }
                railRow("link", "Links", tint: .blue, on: isTab(.links)) { pick(.links) }
                railRow("camera.viewfinder", "Screenshots", tint: .pink, on: isTab(.screenshots)) { pick(.screenshots) }
                railRow("chevron.left.forwardslash.chevron.right", "Code", tint: .purple, on: isTab(.code)) { pick(.code) }
                railRow("doc.richtext", "Files", tint: .teal, on: isTab(.files)) { pick(.files) }
                railRow("paintpalette", "Colors", tint: .orange, on: isTab(.colors)) { pick(.colors) }
                section("Stacks")
                if model.stacks.isEmpty {
                    Text("Things that share a PR, a ticket or a Figma file stack up here. You can also make your own.")
                        .font(.system(size: 10.5)).foregroundStyle(c.soft).padding(.horizontal, 10).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.stacks) { s in
                    railRow(
                        model.isCollecting(s) ? "record.circle.fill" : s.auto ? "sparkles" : "square.stack.fill", s.name, count: "\(s.itemIDs.count)",
                        tint: s.color, on: model.scope == .stack(s.id)
                    ) {
                        picked = false; model.show(.stack(s.id))
                    }
                    .contextMenu {
                        Button {
                            picked = false; model.show(.stack(s.id)); model.copyForAI()
                        } label: {
                            Label("Copy for AI", systemImage: "sparkles")
                        }
                        if model.isCollecting(s) {
                            Button {
                                model.stopCollecting()
                            } label: {
                                Label("Stop collecting", systemImage: "stop.circle")
                            }
                        } else {
                            Button {
                                model.collect(into: s)
                            } label: {
                                Label("Collect new copies here", systemImage: "tray.and.arrow.down")
                            }
                        }
                        if !s.auto {
                            Button(role: .destructive) {
                                model.delete(s)
                            } label: {
                                Label("Delete stack", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func isTab(_ t: Tab) -> Bool { model.scope == .tab && model.tab == t && model.text.isEmpty }
    private func pick(_ t: Tab) { model.text = ""; model.detail = nil; picked = false; withAnimation(.spring(duration: 0.3)) { model.tab = t } }

    private func section(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(c.soft).padding(.leading, 10).padding(.top, 12)
            .padding(.bottom, 2)
    }

    private func railRow(_ icon: String, _ title: String, count: String? = nil, tint: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).frame(width: 16)
                Text(title).font(.system(size: 13, weight: on ? .semibold : .regular)).foregroundStyle(on ? c.text : c.text.opacity(0.75)).lineLimit(
                    1)
                Spacer()
                if let count { Text(count).font(.system(size: 11, weight: .medium)).foregroundStyle(c.soft).monospacedDigit() }
            }
            .padding(.horizontal, 10).frame(height: 29)
            .background(RoundedRectangle(cornerRadius: c.glassy ? 14 : 8, style: .continuous).fill(on ? c.field : .clear))
            .overlay { if c.glassy && on { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(c.rim, lineWidth: 0.8) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Grid

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "bird").font(.system(size: 34, weight: .light)).foregroundStyle(c.soft)
            Text(
                model.text.isEmpty
                    ? "Nothing here yet. Copy a link, a colour or some code, or take a screenshot. It lands here."
                    : "Nothing matched that. Try fewer words, or just a type like \"screenshot\"."
            )
            .font(.system(size: 13)).foregroundStyle(c.soft).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.sections, id: \.0) { label, group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(label.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(c.soft)
                            Flow(spacing: 12, width: cardsWidth) {
                                ForEach(group) { item in tile(item).id(item.id) }
                            }
                        }
                    }
                }
                .padding(4)
                .id("top")
            }
            .onAppear { proxy.scrollTo("top", anchor: .top) }
            .onChange(of: model.selected) { _, _ in
                if picked, let item = model.current { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(item.id, anchor: .center) } }
            }
        }
    }

    private func tile(_ item: Item, width: CGFloat? = nil, preview: CGFloat = 100) -> some View {
        let index = model.items.firstIndex(of: item) ?? 0
        return Tile(
            item: item, selected: picked && index == model.selected, copied: model.copiedID == item.id, pinned: model.pinned.contains(item.id), c: c,
            glass: glass,
            width: width ?? tileWidth, previewHeight: preview
        )
        .onTapGesture {
            picked = true
            model.selected = index
            if NSApp.currentEvent?.clickCount == 2 { model.use(item) } else { model.copyPrimary(item) }
        }
        .onDrag { ShelfModel.provider(for: item) }
        .contextMenu {
            ForEach(model.actions(for: item, translate: { translating = $0 })) { a in Button(action: a.run) { Label(a.title, systemImage: a.icon) } }
            CopyAsMenu(model: model, item: item)
            deleteButton(item)
        }
    }

    // MARK: Action bar

}
