import AppKit
import CoreImage
import SwiftUI
import Vision

// Something private found in a screenshot, and where it sits (Vision's normalised box, origin bottom-left).
struct Finding: Identifiable, Equatable {
    let id: Int
    let label: String
    let preview: String
    let box: CGRect
}

enum ShareSafe {
    struct Scan { let image: CGImage; let findings: [Finding] }

    private static var cache: [Int64: Scan] = [:]
    private static let lock = NSLock()

    private static func cached(_ id: Int64) -> Scan? { lock.lock(); defer { lock.unlock() }; return cache[id] }
    private static func remember(_ s: Scan, for id: Int64) {
        lock.lock(); defer { lock.unlock() }; if cache.count > 40 { cache.removeAll() }; cache[id] = s
    }

    // Reads the text on this Mac and checks each line for credentials, emails, phone numbers and passwords.
    static func scan(_ item: Item) async -> Scan? {
        if let hit = cached(item.id) { return hit }
        guard let path = item.path else { return nil }
        let result: Scan? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { return nil }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: img).perform([req])
            var findings: [Finding] = []
            for obs in req.results ?? [] {
                guard let cand = obs.topCandidates(1).first else { continue }
                for (label, range) in sensitive(in: cand.string) {
                    guard let box = try? cand.boundingBox(for: range)?.boundingBox else { continue }
                    findings.append(Finding(id: findings.count, label: label, preview: mask(String(cand.string[range])), box: box))
                }
            }
            return Scan(image: img, findings: findings)
        }.value
        if let result { remember(result, for: item.id) }
        return result
    }

    static func sensitive(in s: String) -> [(String, Range<String.Index>)] {
        var out = Secrets.matches(in: s).map { ($0.name, $0.range) }
        let rules: [(String, String, Int)] = [
            ("Password", #"(?i)\b(?:password|passwd|pwd|secret|api[_-]?key|token)\s*[:=]\s*(\S+)"#, 1),
            ("Password in a link", #"://[^:/\s@]+:([^@/\s]+)@"#, 1),
            ("Email address", #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, 0),
        ]
        let ns = s as NSString
        for (label, pattern, group) in rules {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                guard let r = Range(m.range(at: group), in: s), !out.contains(where: { $0.1.overlaps(r) }) else { continue }
                out.append((label, r))
            }
        }
        if let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue) {
            for m in d.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                guard let r = Range(m.range, in: s), s[r].filter(\.isNumber).count >= 8, !out.contains(where: { $0.1.overlaps(r) }) else { continue }
                out.append(("Phone number", r))
            }
        }
        return out
    }

    private static func mask(_ s: String) -> String {
        s.count <= 6 ? String(repeating: "•", count: s.count) : String(s.prefix(4)) + String(repeating: "•", count: min(8, s.count - 4))
    }

    // Covers each region with its own average colour. A solid patch, so nothing can be recovered from it, unlike blur.
    static func render(_ image: CGImage, hiding boxes: [CGRect]) -> CGImage? {
        let base = CIImage(cgImage: image)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        var out = base
        for b in boxes {
            let pad = max(3, b.height * h * 0.18)
            let r = CGRect(x: b.minX * w - pad, y: b.minY * h - pad, width: b.width * w + 2 * pad, height: b.height * h + 2 * pad).intersection(
                base.extent)
            guard !r.isEmpty else { continue }
            var px = [UInt8](repeating: 0, count: 4)
            let avg = base.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
            ctx.render(
                avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
            let fill = CIImage(color: CIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255)).cropped(to: r)
            out = fill.composited(over: out)
        }
        return ctx.createCGImage(out, from: base.extent)
    }

    // Beside the original when saving, in a temp folder when dragging.
    static func file(for item: Item, _ image: CGImage, beside: Bool = false) -> URL? {
        let original = item.path.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        let dir = beside && original != nil ? original! : FileManager.default.temporaryDirectory.appendingPathComponent("Sill", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = ((item.path as NSString?)?.deletingPathExtension as NSString?)?.lastPathComponent ?? "Screenshot"
        let url = dir.appendingPathComponent("\(name) (safe).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else {
            return nil
        }
        return url
    }
}

struct ShareSafeView: View {
    let item: Item
    let c: Palette
    var onBack: () -> Void
    var onDone: (String) -> Void
    @State private var scan: ShareSafe.Scan?
    @State private var off: Set<Int> = []
    @State private var output: CGImage?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BackRow(title: "Share safely", c: c, onBack: onBack)
            HStack(alignment: .top, spacing: 22) {
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                side.frame(width: 330)
            }
        }
        .task(id: item.id) {
            loading = true
            scan = await ShareSafe.scan(item)
            loading = false
            rerender()
        }
    }

    private var preview: some View {
        GeometryReader { geo in
            if let output {
                let size = fit(CGSize(width: output.width, height: output.height), in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: output, scale: 1).resizable().frame(width: size.width, height: size.height)
                    ForEach(scan?.findings.filter { !off.contains($0.id) } ?? []) { f in
                        RoundedRectangle(cornerRadius: 3).stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: f.box.width * size.width + 6, height: f.box.height * size.height + 6)
                            .offset(x: f.box.minX * size.width - 3, y: (1 - f.box.maxY) * size.height - 3)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(c.line))
                .frame(width: geo.size.width, height: geo.size.height)
                .onDrag { url().flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the screenshot on this Mac…").font(.system(size: 12)).foregroundStyle(c.soft)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let scan {
                Label(scan.findings.isEmpty ? "Nothing private found" : "Hidden automatically", systemImage: "checkmark.shield.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(c.text).symbolRenderingMode(.multicolor)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(scan.findings) { f in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(c.text)
                                    Text(f.preview).font(.system(size: 11, design: .monospaced)).foregroundStyle(c.soft).lineLimit(1)
                                }
                                Spacer()
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { !off.contains(f.id) },
                                        set: { on in
                                            if on { off.remove(f.id) } else { off.insert(f.id) }
                                            rerender()
                                        })
                                ).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                            }
                            .padding(9).background(RoundedRectangle(cornerRadius: 9).fill(c.raised.opacity(0.7)))
                        }
                    }
                }
                Text("Found by reading the screenshot on your Mac. Nothing is uploaded. Text Sill can't read, like handwriting, isn't covered.")
                    .font(.system(size: 11)).foregroundStyle(c.soft).fixedSize(horizontal: false, vertical: true)
                Spacer()
                HStack(spacing: 8) {
                    Chip(icon: "doc.on.doc", title: "Copy safe image", primary: true, c: c) {
                        guard let output else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([NSImage(cgImage: output, size: .zero)])
                        NSPasteboard.general.markOwn()
                        onDone("Safe image copied")
                    }
                    Chip(icon: "square.and.arrow.down", title: "Save copy", c: c) {
                        if let output, let u = ShareSafe.file(for: item, output, beside: true) {
                            NSWorkspace.shared.activateFileViewerSelecting([u]); onDone("Saved next to the original")
                        }
                    }
                }
                Text("Or drag the picture straight into Slack.").font(.system(size: 11)).foregroundStyle(c.soft)
            } else if !loading {
                Text("Couldn't open this image.").foregroundStyle(c.soft)
            }
        }
    }

    private func rerender() {
        guard let scan else { return }
        output = ShareSafe.render(scan.image, hiding: scan.findings.filter { !off.contains($0.id) }.map(\.box))
    }

    private func url() -> URL? { output.flatMap { ShareSafe.file(for: item, $0) } }

    private func fit(_ s: CGSize, in box: CGSize) -> CGSize {
        let k = min(box.width / max(s.width, 1), box.height / max(s.height, 1))
        return CGSize(width: s.width * k, height: s.height * k)
    }
}
