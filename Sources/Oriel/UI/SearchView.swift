import AppKit
import SwiftUI

@MainActor
final class SearchModel: ObservableObject {
    @Published var text = "" { didSet { run() } }
    @Published private(set) var query = Query()
    @Published private(set) var results: [Item] = []
    @Published var selection: Int = 0

    init() { run() }

    func run() {
        query = Query.parse(text)
        results = Store.shared.search(query)
        selection = 0
    }

    func act(on item: Item) {
        if let path = item.path {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.body, forType: .string)
            NSPasteboard.general.markOwn()
        }
    }
}

struct SearchView: View {
    @ObservedObject var model: SearchModel
    var onClose: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                TextField("Ask for anything you copied, downloaded or screenshotted", text: $model.text)
                    .textFieldStyle(.plain).font(.system(size: 20)).focused($focused)
                    .onSubmit { if model.results.indices.contains(model.selection) { model.act(on: model.results[model.selection]); onClose() } }
                    .onKeyPress(.downArrow) {
                        model.selection = min(model.selection + 1, max(model.results.count - 1, 0)); return .handled
                    }
                    .onKeyPress(.upArrow) {
                        model.selection = max(model.selection - 1, 0); return .handled
                    }
                    .onKeyPress(.escape) {
                        onClose(); return .handled
                    }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            if !model.query.chips.isEmpty {
                HStack(spacing: 6) {
                    Text("Looking for").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.query.chips, id: \.self) { chip in
                        Text(chip).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Swatch.accent.opacity(0.14))).foregroundStyle(Swatch.accent)
                    }
                    if !model.query.words.isEmpty {
                        Text("“\(model.query.words.joined(separator: " "))”").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.bottom, 10)
            }
            Divider()
            if model.results.isEmpty {
                Text(
                    model.text.isEmpty
                        ? "Nothing yet. Oriel remembers what you copy, download and screenshot from now on." : "Nothing matched. Try fewer words."
                )
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView { LazyVStack(spacing: 2) { rows }.padding(8) }.frame(maxHeight: 380)
            }
            HStack(spacing: 14) {
                Label("open or copy", systemImage: "return")
                Spacer()
                Text("\(model.results.count) found")
            }
            .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.vertical, 9)
            .background(Swatch.well)
        }
        .frame(width: 680)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { focused = true }
    }
}

extension SearchView {
    @ViewBuilder var rows: some View {
        ForEach(Array(model.results.prefix(40).enumerated()), id: \.element.id) { i, item in
            ResultRow(item: item, selected: i == model.selection)
                .onTapGesture {
                    model.act(on: item); onClose()
                }
        }
    }
}

struct ResultRow: View {
    let item: Item
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(item.kind.tint)
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(item.kind.tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if !preview.isEmpty { Text(preview).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.ts, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.caption).foregroundStyle(.secondary)
                if let where_ = item.kind == .link ? (item.app.map { "from \($0)" } ?? item.source) : (item.source ?? item.app) {
                    Text(where_).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Swatch.accent.opacity(0.12) : .clear))
    }

    private var preview: String {
        let flat = item.body.replacingOccurrences(of: "\n", with: " ")
        return flat == item.title ? "" : String(flat.prefix(160))
    }
}
