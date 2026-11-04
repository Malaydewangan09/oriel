import AppKit
import SwiftUI

struct ClassicShelfView: View {
    @ObservedObject var model: ShelfModel
    var onClose: () -> Void
    @FocusState private var searching: Bool
    @AppStorage(Pref.appearance) private var appearance: Appearance = .auto
    @Environment(\.colorScheme) private var scheme
    @State private var translating: String?
    private var c: Palette { .make(.classic, dark: appearance.isDark(scheme)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            hintRow.font(.system(size: 11.5))
            if model.items.isEmpty { empty } else { shelf }
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 18)
        .onAppear {
            model.reload(); searching = true
        }
        .modifier(TranslateSheet(text: $translating))
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                SillMark().frame(width: 17, height: 17).keyframeAnimator(initialValue: 1.0, trigger: model.caught) { v, k in
                    v.scaleEffect(k)
                } keyframes: { _ in
                    SpringKeyframe(1.3, duration: 0.14); SpringKeyframe(1.0, duration: 0.35)
                }
                Text("Sill").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(c.text).padding(.trailing, 8)
            ForEach(Array(Tab.allCases.enumerated()), id: \.element) { i, tab in
                let on = model.tab == tab && model.text.isEmpty
                Button {
                    model.text = ""; withAnimation(.spring(duration: 0.3)) { model.tab = tab }
                } label: {
                    Text(tab.rawValue).font(.system(size: 12.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? c.shell : c.soft)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background { if on { Capsule().fill(c.text) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("⌘\(i + 1)")
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(c.soft)
                TextField("Ask: links from slack yesterday", text: $model.text).textFieldStyle(.plain).focused($searching).foregroundStyle(c.text)
                    .onKeyPress(.escape) {
                        onClose(); return .handled
                    }
                    .onKeyPress(.leftArrow) {
                        withAnimation(.easeOut(duration: 0.12)) { model.move(-1) }; return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        withAnimation(.easeOut(duration: 0.12)) { model.move(1) }; return .handled
                    }
                    .onKeyPress(keys: ["y"]) { press in
                        guard press.modifiers.contains(.command), let item = model.current else { return .ignored }
                        model.quickLook(item); return .handled
                    }
                    .onKeyPress(characters: .decimalDigits) { press in
                        guard press.modifiers.contains(.command), let n = Int(press.characters), (1...Tab.allCases.count).contains(n) else {
                            return .ignored
                        }
                        model.text = ""; withAnimation(.spring(duration: 0.3)) { model.tab = Tab.allCases[n - 1] }; return .handled
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
            .font(.system(size: 13)).padding(.horizontal, 12).frame(width: 340, height: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(c.field))
            Menu {
                LookPickers()
            } label: {
                Image(systemName: appearance == .light ? "sun.max" : appearance == .dark ? "moon" : "circle.lefthalf.filled").foregroundStyle(c.soft)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Design and appearance")
        }
    }

    private var hintRow: some View {
        HStack(spacing: 6) {
            if !model.query.chips.isEmpty {
                Text("Looking for").foregroundStyle(c.soft)
                ForEach(model.query.chips, id: \.self) {
                    Text($0).fontWeight(.semibold).padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(c.accent.opacity(0.16)))
                        .foregroundStyle(c.accent)
                }
                if !model.query.words.isEmpty { Text("“\(model.query.words.joined(separator: " "))”").foregroundStyle(c.soft) }
            } else {
                Group {
                    Text("← → to move").foregroundStyle(c.soft)
                    Text("·").foregroundStyle(c.soft.opacity(0.6))
                    Text("return to copy or open").foregroundStyle(c.soft)
                    Text("·").foregroundStyle(c.soft.opacity(0.6))
                    Text("⌘Y to look closer").foregroundStyle(c.soft)
                    Text("·").foregroundStyle(c.soft.opacity(0.6))
                    Text("drag anywhere").foregroundStyle(c.soft)
                }
            }
            Spacer()
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill").fontWeight(.semibold).foregroundStyle(c.accent)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "bird").font(.system(size: 34, weight: .light)).foregroundStyle(c.soft)
            Text(
                model.tab == .pinned && model.text.isEmpty
                    ? "Nothing pinned yet. Right-click a card, or use its pin, to keep it here for good."
                    : model.text.isEmpty
                        ? "Nothing shiny yet. Copy a link, a colour or some code, or take a screenshot. It lands here."
                        : "Nothing matched that. Try fewer words, or just a type like “screenshot”."
            )
            .font(.system(size: 13)).foregroundStyle(c.soft).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var shelf: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(model.sections, id: \.0) { label, group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(label.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(c.soft).padding(
                                .leading, 4)
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(group) { item in card(item).id(item.id) }
                            }
                        }
                    }
                }
                .padding(.vertical, 6).padding(.horizontal, 4)
            }
            .frame(height: 226)
            .onChange(of: model.selected) { _, _ in
                if let item = model.current { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(item.id, anchor: .center) } }
            }
        }
    }

    private func card(_ item: Item) -> some View {
        let index = model.items.firstIndex(of: item) ?? 0
        return Card(
            item: item, pinned: model.pinned.contains(item.id), selected: index == model.selected, copied: model.copiedID == item.id,
            actions: model.actions(for: item, translate: { translating = $0 })
        )
        .onTapGesture {
            model.selected = index; model.use(item)
        }
        .onDrag { ShelfModel.provider(for: item) }
        .contextMenu {
            ForEach(model.actions(for: item, translate: { translating = $0 })) { a in Button(action: a.run) { Label(a.title, systemImage: a.icon) } }
            if item.secret == nil, item.path == nil {
                let options = Transform.available(for: item.body)
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
            Divider()
            Button(role: .destructive) {
                model.delete(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.9)), removal: .opacity))
    }

}

struct Card: View {
    let item: Item
    let pinned: Bool
    let selected: Bool
    let copied: Bool
    let actions: [CardAction]
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if item.secret != nil { SecretPreview(item: item) } else { Preview(look: Look.of(item)) }
            }
            .frame(width: 200, height: 130).clipped()
            .overlay(alignment: .topTrailing) {
                if hovering {
                    HStack(spacing: 4) {
                        ForEach(actions.prefix(4)) { a in
                            Button(action: a.run) {
                                Image(systemName: a.icon).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                                    .background(Circle().fill(.ultraThickMaterial)).foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain).help(a.title)
                        }
                    }
                    .padding(7).transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .topTrailing)))
                }
            }
            .overlay {
                if copied {
                    ZStack {
                        Color.black.opacity(0.35)
                        VStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 30))
                            Text("Copied").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: item.lookIcon).font(.system(size: 10, weight: .bold))
                    Text(item.lookLabel).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                }
                .foregroundStyle(item.lookTint)
                Text(meta).font(.system(size: 11)).foregroundStyle(Swatch.inkSoft).lineLimit(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
        }
        .frame(width: 200)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(
                    selected ? Swatch.indigo : (hovering ? Swatch.indigo.opacity(0.4) : Swatch.hairline),
                    lineWidth: selected ? 2.5 : (hovering ? 1.5 : 1))
        )
        .shadow(color: .black.opacity(hovering || selected ? 0.16 : 0.07), radius: hovering ? 12 : 7, y: hovering ? 7 : 3)
        .scaleEffect(hovering ? 1.03 : (selected ? 1.01 : 1))
        .offset(y: hovering ? -3 : 0)
        .animation(.spring(duration: 0.25, bounce: 0.3), value: hovering)
        .animation(.easeOut(duration: 0.15), value: selected)
        .onHover { hovering = $0 }
    }

    private var meta: String {
        guard let o = item.origin else { return item.when }
        return item.source == Item.notchSource ? "\(o) · \(item.when)" : "from \(o) · \(item.when)"
    }

}
