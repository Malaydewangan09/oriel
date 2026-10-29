import AppKit
import Quartz
import SwiftUI

// The notch outline: flat top flush with the screen edge, small outward "ears" at the top corners, rounded bottom.
struct NotchShape: Shape {
    var ear: CGFloat = 10
    var bottom: CGFloat
    // Both animate, so the ears can fold away as the panel opens.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, e = min(ear, w / 4), b = min(bottom, (w - 2 * e) / 2, h / 2)
        // Like Apple's notch: each ear flares over 1.6x its width and eases into the side, and the bottom corners are
        // continuous curves instead of circle arcs, so nothing reads as a sharp turn.
        let d = min(e * 1.6, max(h - b, 0))
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addCurve(to: CGPoint(x: w - e, y: d), control1: CGPoint(x: w - e * 0.5, y: 0), control2: CGPoint(x: w - e, y: d * 0.4))
        p.addLine(to: CGPoint(x: w - e, y: h - b))
        p.addCurve(to: CGPoint(x: w - e - b, y: h), control1: CGPoint(x: w - e, y: h - b * 0.35), control2: CGPoint(x: w - e - b * 0.35, y: h))
        p.addLine(to: CGPoint(x: e + b, y: h))
        p.addCurve(to: CGPoint(x: e, y: h - b), control1: CGPoint(x: e + b * 0.35, y: h), control2: CGPoint(x: e, y: h - b * 0.35))
        p.addLine(to: CGPoint(x: e, y: d))
        p.addCurve(to: .zero, control1: CGPoint(x: e, y: d * 0.4), control2: CGPoint(x: e * 0.5, y: 0))
        p.closeSubpath()
        return p
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var peek: Item?
    @Published var dropHint = false  // a file is being dragged over the notch
    var notch = CGSize(width: 200, height: 32)
    @Published var full = CGSize(width: 1200, height: 360)
    var topInset: CGFloat = 32
}

struct NotchContainer: View {
    @ObservedObject var state: NotchState
    let model: ShelfModel
    var onClose: () -> Void
    var onDrop: ([URL], String?) -> Void = { _, _ in }
    @AppStorage(Pref.appearance) private var appearance: Appearance = .auto
    @AppStorage(Pref.design) private var design: Design = .glass
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // The ears curve outward where the shape meets the top edge, like the hardware notch. They need 14pt of
        // transparent window on each side: invisible on screen, dark only in window-only screenshots.
        let ear: CGFloat = 14
        let wing: CGFloat = 170
        let winged = !state.expanded && (state.peek != nil || state.dropHint)
        let size =
            state.expanded
            ? CGSize(width: state.full.width + 2 * ear, height: state.full.height)
            : winged
                ? CGSize(width: state.notch.width + 2 * wing + 2 * ear, height: state.notch.height + 4)
                : CGSize(width: state.notch.width + 2 * ear, height: state.notch.height)
        ZStack(alignment: .top) {
            // Collapsed it is always black, so it looks like the notch itself. Expanded it takes the chosen appearance.
            let c = Palette.make(design, dark: appearance.isDark(scheme))
            let shape = NotchShape(ear: ear, bottom: state.expanded ? 30 : 12)
            if design == .glass {
                // Glass from the first frame of the open to the last of the close. It only hides behind a peek.
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(appearance.isDark(scheme) ? Color.black.opacity(0.16) : Color.white.opacity(0.06)))
                    .opacity(winged ? 0 : 1)
                // The hardware notch is already black, so the black shape is only needed to draw the peek's wings.
                shape.fill(Color.black)
                    .opacity(winged ? 1 : 0)
            } else {
                shape.fill(state.expanded ? c.shell : .black)
                    .overlay(
                        NotchShape(ear: ear, bottom: state.expanded ? 30 : 12).stroke(
                            state.expanded && design == .classic ? c.line : .clear, lineWidth: 1))
            }
            if state.dropHint, !state.expanded {
                DropHintView(notchWidth: state.notch.width, wing: wing).frame(height: state.notch.height + 4).transition(.opacity)
            } else if let item = state.peek, !state.expanded {
                PeekView(item: item, notchWidth: state.notch.width, wing: wing).frame(height: state.notch.height + 4)
                    .transition(.opacity)
            }
            Group {
                if design == .classic {
                    ClassicShelfView(model: model, onClose: onClose)
                } else {
                    ShelfView(model: model, width: state.full.width, onClose: onClose)
                }
            }
            .padding(.top, state.topInset)
            .frame(width: state.full.width, height: state.full.height, alignment: .top)
            .opacity(state.expanded ? 1 : 0)
            .frame(width: max(size.width - 2 * ear, 1), height: size.height, alignment: .top)
            .clipped()
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Dropping onto the open shelf keeps the file too.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async { onDrop([url], nil) }
                }
            }
            return !providers.isEmpty
        }
    }
}

// Shown beside the notch while something is dragged over it.
struct DropHintView: View {
    let notchWidth: CGFloat
    let wing: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Label("Keep in Oriel", systemImage: "plus.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                .frame(width: wing - 10, alignment: .leading).padding(.leading, 16)
            Spacer().frame(width: notchWidth)
            Text("Drop here").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                .frame(width: wing - 10, alignment: .trailing).padding(.trailing, 16)
        }
    }
}

// What the notch shows for a moment after catching something: the bird on the left of the notch, what was saved on the right.
struct PeekView: View {
    let item: Item
    let notchWidth: CGFloat
    let wing: CGFloat
    private var collecting: String? { item.secret == nil ? UserDefaults.standard.string(forKey: Pref.collectName) : nil }
    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Group {
                    if item.secret == nil {
                        OrielMark().fill(.white).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "lock.fill").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.orange)
                    }
                }
                .keyframeAnimator(initialValue: 1.0, trigger: item.id) { v, k in
                    v.scaleEffect(k)
                } keyframes: { _ in
                    SpringKeyframe(1.3, duration: 0.14); SpringKeyframe(1.0, duration: 0.35)
                }
                Text(
                    item.secret.map { "\($0) caught" } ?? (item.source == ClaudeAgent.source ? "Claude" : collecting.map { "Into \($0)" } ?? "Saved")
                ).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
            }
            .frame(width: wing - 10, alignment: .leading).padding(.leading, 16)
            Spacer().frame(width: notchWidth)
            HStack(spacing: 7) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.82)).lineLimit(1).truncationMode(.middle)
                badge
            }
            .frame(width: wing - 10, alignment: .trailing).padding(.trailing, 14)
        }
        .task(id: item.id) {
            if let p = item.path, item.isImage { thumb = await Preview.thumbnail(URL(fileURLWithPath: p)) }
        }
    }

    // A small picture of the thing itself, where there is one.
    @ViewBuilder private var badge: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        if item.secret != nil {
            EmptyView()
        } else {
            switch Look.of(item) {
            case .image:
                Group { if let thumb { Image(nsImage: thumb).resizable().scaledToFill() } else { Color.white.opacity(0.15) } }
                    .frame(width: 30, height: 20).clipShape(shape).overlay(shape.stroke(.white.opacity(0.25), lineWidth: 0.5))
            case .color(let c, _):
                Circle().fill(Color(nsColor: c)).frame(width: 16, height: 16).overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
            case .link(let host, _):
                Text(String(host.prefix(1)).uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(
                        shape.fill(LinearGradient(colors: Swatch.gradient(for: host), startPoint: .topLeading, endPoint: .bottomTrailing)))
            case .code:
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Swatch.lavender)
            case .file:
                Image(systemName: "doc.fill").font(.system(size: 12)).foregroundStyle(Swatch.tealLight)
            case .text:
                Image(systemName: "text.quote").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var title: String {
        if item.secret != nil { return "forgotten in 2 min" }
        return switch Look.of(item) {
        case .link(let host, _): host
        case .color(_, let hex): hex.hasPrefix("#") ? hex : "#" + hex
        case .code: "code"
        case .image: item.kind == .screenshot ? "screenshot" : "image"
        case .file(let u): u.lastPathComponent
        case .text(let t): t.replacingOccurrences(of: "\n", with: " ")
        }
    }
}
