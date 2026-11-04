import SwiftUI

struct Tile: View {
    let item: Item
    let selected: Bool
    let copied: Bool
    let pinned: Bool
    let c: Palette
    var glass = false
    var width: CGFloat? = nil  // the grid's column width, so content can never spill into the next tile
    var previewHeight: CGFloat = 100
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group { if item.secret != nil { SecretPreview(item: item) } else { Preview(look: Look.of(item)) } }
                .frame(maxWidth: .infinity).frame(height: previewHeight).clipped()
                // Says what a click does, so the shelf never leaves you guessing.
                .overlay(alignment: .topTrailing) {
                    if hovering && !copied {
                        Label("Copy", systemImage: "doc.on.doc").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(.black.opacity(0.6)))
                            .padding(8)
                            .transition(.opacity)
                    }
                }
                .overlay {
                    if copied {
                        ZStack {
                            Color.black.opacity(0.35)
                            Label("Copied", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        }
                        .transition(.opacity)
                    }
                }
            HStack(spacing: 6) {
                // The card already shows what it is, so the footer only says where it came from and when.
                Image(systemName: item.lookIcon).font(.system(size: 10, weight: .bold)).foregroundStyle(item.lookTint)
                Text(item.origin ?? item.lookLabel).font(.system(size: 11)).foregroundStyle(c.text.opacity(0.8)).lineLimit(1)
                if pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                Spacer(minLength: 4)
                Text(item.ts.formatted(.dateTime.hour().minute())).font(.system(size: 10.5)).foregroundStyle(c.soft).lineLimit(1).monospacedDigit()
            }
            .padding(.horizontal, 11).frame(height: 34)
        }
        .frame(minWidth: width, maxWidth: width ?? .infinity)
        .background(c.raised)
        .clipShape(RoundedRectangle(cornerRadius: glass ? 18 : 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: glass ? 18 : 14, style: .continuous)
                .stroke(selected ? c.accent : (glass ? .clear : (hovering ? c.soft.opacity(0.5) : c.line)), lineWidth: selected ? 2 : 1)
        )
        .shadow(color: .black.opacity(glass ? 0.14 : 0.05), radius: glass ? 8 : 5, y: 3)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
