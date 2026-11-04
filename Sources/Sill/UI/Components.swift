import AppKit
import Quartz
import SwiftUI
import Translation

// Design and appearance, as the shelf's menu shows them.
struct LookPickers: View {
    @AppStorage(Pref.design) private var design: Design = .glass
    @AppStorage(Pref.appearance) private var appearance: Appearance = .auto

    var body: some View {
        Picker("Design", selection: $design) { ForEach(Design.allCases) { Text($0.title).tag($0) } }.pickerStyle(.inline)
        Picker("Appearance", selection: $appearance) { ForEach(Appearance.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline)
    }
}

struct Chip: View {
    var icon: String
    var title: String
    var primary = false
    let c: Palette
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) { ChipLabel(icon: icon, title: title, primary: primary, c: c) }.buttonStyle(.plain)
    }
}

struct ChipLabel: View {
    var icon: String
    var title: String
    var primary = false
    let c: Palette
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(height: 30)
        .foregroundStyle(primary ? (c.glassy ? Color.black.opacity(0.88) : c.shell) : c.text)
        .background(Capsule().fill(primary ? (c.glassy ? Color.white.opacity(0.95) : c.text) : c.field))
        .overlay { if c.glassy && !primary { Capsule().stroke(c.rim, lineWidth: 0.8) } }
        .contentShape(Capsule())
    }
}

struct BackRow: View {
    let title: String
    let c: Palette
    var onBack: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) { ChipLabel(icon: "chevron.left", title: "Back", c: c) }.buttonStyle(.plain).help("Esc")
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(c.soft)
            Spacer()
        }
    }
}

// Lays children left to right and wraps, like words in a paragraph.
// A fixed width keeps rows stable while the panel animates open, when proposed widths are still in flux.
struct Flow: Layout {
    var spacing: CGFloat = 12
    var width: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: width ?? proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: width ?? bounds.width, subviews) {
            for (i, x, w) in row.items {
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: ProposedViewSize(width: w, height: nil))
            }
        }
    }

    // Equal columns: every tile is the same width, in every row and every day, so the grid reads as one surface.
    static let minTile: CGFloat = 180

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [(Int, CGFloat, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] {
        let w = width.isFinite ? width : 4 * (Self.minTile + spacing)
        let cols = max(1, Int((w + spacing) / (Self.minTile + spacing)))
        let tile = ((w - spacing * CGFloat(cols - 1)) / CGFloat(cols)).rounded(.down)
        var rows: [(items: [(Int, CGFloat, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var y: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: cols) {
            let idx = Array(start..<min(start + cols, subviews.count))
            let h = idx.map { subviews[$0].sizeThatFits(ProposedViewSize(width: tile, height: nil)).height }.max() ?? 0
            let placed = idx.enumerated().map { (n, i) in (i, CGFloat(n) * (tile + spacing), tile) }
            rows.append((placed, y, CGFloat(idx.count) * (tile + spacing) - spacing, h))
            y += h + spacing
        }
        return rows
    }
}

// Apple's on-device translation popover, where the system supports it (macOS 14.4 and later).
struct TranslateSheet: ViewModifier {
    @Binding var text: String?
    func body(content: Content) -> some View {
        if #available(macOS 14.4, *) {
            content.translationPresentation(isPresented: Binding(get: { text != nil }, set: { if !$0 { text = nil } }), text: text ?? "")
        } else {
            content
        }
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    // Quick Look drops a data source that no window in the responder chain claims.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = Peek.shared }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}
