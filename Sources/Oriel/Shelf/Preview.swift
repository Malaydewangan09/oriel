import AppKit
import Quartz
import QuickLookThumbnailing
import SwiftUI

// A secret: masked, with a live countdown until Oriel forgets it.
struct SecretPreview: View {
    let item: Item
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int((item.expires ?? ctx.date).timeIntervalSince(ctx.date)))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 12, weight: .bold))
                    Text(item.secret ?? "Secret").font(.system(size: 12, weight: .semibold))
                }
                Text(masked).font(.system(size: 13, design: .monospaced)).lineLimit(1)
                Spacer()
                HStack(spacing: 6) {
                    Capsule().fill(.white.opacity(0.18)).frame(width: 90, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(.orange).frame(width: 90 * CGFloat(Double(left) / Secrets.lifetime), height: 4)
                        }
                    Text("forgotten in \(left / 60):\(String(format: "%02d", left % 60))").font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.white.opacity(0.9)).padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LinearGradient(colors: Swatch.secret, startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private var masked: String {
        let t = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 8 ? String(t.prefix(4)) + String(repeating: "•", count: 10) + String(t.suffix(4)) : String(repeating: "•", count: 12)
    }
}

struct Preview: View {
    let look: Look
    @State private var thumb: NSImage?
    @AppStorage(Pref.appearance) private var appearance: Appearance = .auto
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch look {
        case .link(let host, let path):
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: Swatch.gradient(for: host), startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(String(host.prefix(1)).uppercased()).font(.system(size: 48, weight: .bold, design: .rounded)).foregroundStyle(
                    .white.opacity(0.12)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.trailing, 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(host).font(.system(size: 9, weight: .semibold)).textCase(.uppercase).tracking(0.5).foregroundStyle(.white.opacity(0.7))
                    Text(path.isEmpty ? host : path).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(2)
                }
                .padding(11)
            }
        case .code(let s):
            Text(s).font(.system(size: 10, design: .monospaced)).foregroundStyle(Swatch.codeText).lineSpacing(1.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(11)
                .background(Swatch.codeBackground)
        case .color(let c, let hex):
            ZStack(alignment: .bottomLeading) {
                Color(nsColor: c)
                Text(hex.hasPrefix("#") ? hex : "#" + hex).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                    .shadow(radius: 2).padding(11)
            }
        case .text(let s):
            // Plain system text on a quiet tile that follows the panel's appearance.
            let dark = appearance.isDark(scheme)
            Text(s).font(.system(size: 11.5)).foregroundStyle(dark ? Color.white.opacity(0.7) : Swatch.ink.opacity(0.8)).lineSpacing(1.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(11)
                .background(dark ? Swatch.textTileDark : Swatch.textTileLight)
        case .image(let url), .file(let url):
            ZStack {
                Swatch.imageBackdrop
                if let img = thumb ?? Self.thumbs.object(forKey: url as NSURL) {
                    if case_file { Image(nsImage: img).resizable().scaledToFit().padding(10) } else { Image(nsImage: img).resizable().scaledToFill() }
                } else {
                    Image(systemName: case_file ? "doc" : "photo").font(.system(size: 26)).foregroundStyle(Swatch.inkSoft.opacity(0.6))
                }
            }
            .task(id: url) {
                guard Self.thumbs.object(forKey: url as NSURL) == nil else { return }
                let img = await Self.thumbnail(url)
                withAnimation(.easeOut(duration: 0.18)) { thumb = img }
            }
        }
    }

    private var case_file: Bool { if case .file = look { return true }; return false }

    // Real previews from Quick Look, the same engine Finder uses. Generated on this Mac.
    // Kept in memory so reopening the shelf shows previews at once instead of a placeholder first.
    static let thumbs: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>(); c.countLimit = 300; return c
    }()

    static func thumbnail(_ url: URL) async -> NSImage? {
        if let hit = thumbs.object(forKey: url as NSURL) { return hit }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 480, height: 320), scale: 2, representationTypes: .thumbnail)
        guard let img = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).nsImage else { return nil }
        thumbs.setObject(img, forKey: url as NSURL)
        return img
    }

}

// In-process Quick Look, raised above the notch panel. qlmanage opened behind it.
@MainActor
final class Peek: NSObject, QLPreviewPanelDataSource {
    static let shared = Peek()
    private var url: URL?

    var isShowing: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.updateController()
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        panel.orderFrontRegardless()
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
