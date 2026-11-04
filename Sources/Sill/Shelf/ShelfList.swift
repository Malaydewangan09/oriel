import AppKit
import SwiftUI

// The list and preview layout: one line per item on the left, the chosen item in full on the right.
// Text reads better as rows than as clipped cards. Screenshots and colours keep the card grid.

struct ListRow: View {
    let item: Item
    let selected: Bool
    let copied: Bool
    let c: Palette
    var onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            badge
            Text(item.rowLine).font(.system(size: 12.5)).foregroundStyle(c.text.opacity(0.9)).lineLimit(1)
            Spacer(minLength: 6)
            if copied {
                Label("Copied", systemImage: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(c.accent)
            } else if hovering {
                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc").font(.system(size: 11, weight: .semibold)).foregroundStyle(c.text)
                        .padding(.horizontal, 8).frame(height: 22).background(Capsule().fill(c.field))
                }
                .buttonStyle(.plain)
            } else {
                Text(item.rowMeta).font(.system(size: 11)).foregroundStyle(c.soft).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? c.field : (hovering ? c.field.opacity(0.5) : .clear)))
        .overlay { if selected { RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(c.accent.opacity(0.7), lineWidth: 1) } }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var badge: some View {
        if item.isImage {
            Preview(look: Look.of(item)).frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if case .color(let col, _) = Look.of(item), item.secret == nil {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: col)).frame(width: 26, height: 26)
        } else {
            Image(systemName: item.lookIcon).font(.system(size: 11, weight: .bold)).foregroundStyle(item.lookTint)
                .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.field))
        }
    }
}

// The chosen item, readable in full.
struct PreviewPane: View {
    let item: Item
    let c: Palette
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(item.lookLabel).font(.system(size: 12, weight: .semibold)).foregroundStyle(c.text)
                Text(from).font(.system(size: 12)).foregroundStyle(c.soft).lineLimit(1)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        }
        .task(id: item.id) {
            image = nil
            guard item.isImage, let p = item.path else { return }
            let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
                // Downsampled: a Retina screenshot decoded at full size stalls the panel for a pane this small.
                let opts =
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1200,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
            }.value
            image = cg.map { NSImage(cgImage: $0, size: .zero) }
        }
    }

    private var from: String {
        var parts: [String] = []
        if item.source == Item.notchSource { parts.append("dropped on the notch") } else if let s = item.origin { parts.append("from \(s)") }
        parts.append(item.when)
        if item.isText, item.secret == nil { parts.append("\(item.body.count) characters") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if item.secret != nil {
            SecretPreview(item: item).frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            switch Look.of(item) {
            case .image:
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    Preview(look: Look.of(item)).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            case .color(let col, let hex):
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: col)).frame(maxHeight: 160)
                    Text(hex.hasPrefix("#") ? hex : "#" + hex).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(c.text)
                }
            case .file(let u):
                VStack(alignment: .leading, spacing: 12) {
                    Preview(look: Look.of(item)).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(u.lastPathComponent).font(.system(size: 13, weight: .semibold)).foregroundStyle(c.text).lineLimit(2)
                            Text(u.deletingLastPathComponent().path).font(.system(size: 11)).foregroundStyle(c.soft).lineLimit(1).truncationMode(
                                .middle)
                        }
                    }
                }
            case .code(let s):
                ScrollView {
                    Text(s).font(.system(size: 12, design: .monospaced)).foregroundStyle(c.text.opacity(0.9)).lineSpacing(2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .link:
                VStack(alignment: .leading, spacing: 6) {
                    if !item.title.isEmpty, item.title != item.body {
                        Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(c.text)
                    }
                    Text(item.body).font(.system(size: 12.5)).foregroundStyle(c.accent).textSelection(.enabled)
                }
            case .text(let s):
                ScrollView {
                    Text(s).font(.system(size: 13.5)).foregroundStyle(c.text.opacity(0.88)).lineSpacing(3).textSelection(.enabled).frame(
                        maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// Two-finger swipe left on a row, like Mail: a short swipe shows Delete, a long one deletes.
// swipeActions only works inside a List, so this reads the trackpad's horizontal scroll directly.
struct SwipeToDelete: ViewModifier {
    var onDelete: () -> Void
    @State private var offset: CGFloat = 0
    @State private var monitor: Any?
    @State private var axis: Axis?
    private let reveal: CGFloat = 76, commit: CGFloat = 170

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .trailing) {
                if offset < 0 {
                    Button {
                        finish()
                    } label: {
                        Image(systemName: "trash").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: -offset).frame(maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.red))
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
            .onHover { $0 ? start() : stop() }
            .onDisappear(perform: stop)
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            MainActor.assumeIsolated { track(e) }
            return e  // the list only scrolls vertically, so it can still see every event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        axis = nil
        if offset != 0 { withAnimation(.spring(duration: 0.25)) { offset = 0 } }
    }

    private func track(_ e: NSEvent) {
        guard e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return }  // mouse wheels and the coast after lifting are ignored
        if e.phase == .began { axis = nil }
        // Natural scrolling reports deltas in the fingers' direction. Normalise so left is always negative.
        let dx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        if axis == nil, dx != 0 || e.scrollingDeltaY != 0 { axis = abs(dx) > abs(e.scrollingDeltaY) * 1.5 ? .horizontal : .vertical }
        guard axis == .horizontal else { return }
        if e.phase == .ended || e.phase == .cancelled {
            axis = nil
            if offset <= -commit {
                finish()
            } else {
                withAnimation(.spring(duration: 0.25, bounce: 0.2)) { offset = offset < -reveal / 2 ? -reveal : 0 }
            }
        } else {
            offset = min(0, offset + dx)
        }
    }

    private func finish() {
        withAnimation(.easeIn(duration: 0.15)) { offset = -400 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onDelete(); offset = 0
        }
    }
}
