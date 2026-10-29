import AppKit
import CoreImage
import SwiftUI

// Mark up a screenshot before sharing it: pen, arrows, boxes, highlight and blur, drawn on the full-size image.
enum MarkTool: String, CaseIterable, Identifiable {
    case pen = "Pen", arrow = "Arrow", box = "Box", highlight = "Highlight", blur = "Blur"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .pen: "scribble";
        case .arrow: "arrow.up.right";
        case .box: "rectangle";
        case .highlight: "highlighter";
        case .blur: "square.grid.3x3.fill"
        }
    }
}

struct Mark: Identifiable {
    let id = UUID()
    var tool: MarkTool
    var a: CGPoint  // start and end, 0...1 from the image's top-left
    var b: CGPoint
    var color: NSColor
    var points: [CGPoint] = []  // the pen's stroke, same 0...1 space
}

enum Markup {
    // Blur is pixelation: it can't be undone the way a soft blur sometimes can.
    static func pixelated(_ img: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: img)
        guard let f = CIFilter(name: "CIPixellate") else { return nil }
        f.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(max(12, Double(img.width) / 70), forKey: kCIInputScaleKey)
        guard let out = f.outputImage?.cropped(to: ci.extent) else { return nil }
        return CIContext().createCGImage(out, from: ci.extent)
    }

    static func render(_ base: CGImage, _ marks: [Mark], pixel: CGImage?) -> CGImage? {
        let w = CGFloat(base.width), h = CGFloat(base.height)
        guard
            let ctx = CGContext(
                data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(base, in: full)
        let line = max(3, w / 320)
        // Marks are stored from the top-left; Core Graphics draws from the bottom-left.
        func p(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * w, y: (1 - q.y) * h) }
        for m in marks {
            let a = p(m.a), b = p(m.b)
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            ctx.saveGState()
            switch m.tool {
            case .blur:
                if let pixel { ctx.clip(to: rect); ctx.draw(pixel, in: full) }
            case .highlight:
                ctx.setBlendMode(.multiply)
                ctx.setFillColor(Swatch.highlighter.withAlphaComponent(0.55).cgColor)
                ctx.fill(rect)
            case .box:
                ctx.setStrokeColor(m.color.cgColor)
                ctx.setLineWidth(line)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: line * 2, cornerHeight: line * 2, transform: nil))
                ctx.strokePath()
            case .arrow:
                drawArrow(ctx, from: a, to: b, width: line, color: m.color.cgColor)
            case .pen:
                ctx.setStrokeColor(m.color.cgColor)
                ctx.setLineWidth(line)
                ctx.setLineCap(.round); ctx.setLineJoin(.round)
                ctx.addPath(penPath(m.points.map(p)))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    // A freehand stroke through the midpoints of its samples, so a shaky hand still draws a smooth line.
    static func penPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count < 3 { pts.dropFirst().forEach { path.addLine(to: $0) }; return path }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    static func arrowPath(from a: CGPoint, to b: CGPoint, width: CGFloat) -> (shaft: CGPath, head: CGPath) {
        let len = hypot(b.x - a.x, b.y - a.y), angle = atan2(b.y - a.y, b.x - a.x)
        let headLen = min(max(width * 5, len * 0.22), width * 9)
        let spread: CGFloat = .pi / 7
        let base = CGPoint(x: b.x - cos(angle) * headLen * 0.8, y: b.y - sin(angle) * headLen * 0.8)
        let shaft = CGMutablePath(); shaft.move(to: a); shaft.addLine(to: base)
        let head = CGMutablePath()
        head.move(to: b)
        head.addLine(to: CGPoint(x: b.x - cos(angle - spread) * headLen, y: b.y - sin(angle - spread) * headLen))
        head.addLine(to: CGPoint(x: b.x - cos(angle + spread) * headLen, y: b.y - sin(angle + spread) * headLen))
        head.closeSubpath()
        return (shaft, head)
    }

    private static func drawArrow(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, width: CGFloat, color: CGColor) {
        let (shaft, head) = arrowPath(from: a, to: b, width: width)
        ctx.setStrokeColor(color); ctx.setFillColor(color)
        ctx.setLineWidth(width); ctx.setLineCap(.round)
        ctx.addPath(shaft); ctx.strokePath()
        ctx.addPath(head); ctx.fillPath()
    }
}

struct MarkupView: View {
    let item: Item
    let c: Palette
    var onBack: () -> Void
    var onDone: (String) -> Void
    @State private var base: CGImage?
    @State private var pixel: CGImage?
    @State private var output: CGImage?
    @State private var marks: [Mark] = []
    @State private var draft: Mark?
    @State private var tool: MarkTool = .pen
    @State private var color = NSColor.systemRed
    private let colors: [NSColor] = [.systemRed, .systemYellow, .systemBlue, .white]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BackRow(title: "Mark up", c: c, onBack: onBack).fixedSize()
                Spacer()
                ForEach(MarkTool.allCases) { t in
                    Button {
                        tool = t
                    } label: {
                        Label(t.rawValue, systemImage: t.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tool == t ? c.text : c.soft)
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(Capsule().fill(tool == t ? c.field : .clear))
                    }
                    .buttonStyle(.plain)
                }
                // Always there, so switching tools never shifts the row. Faded for tools that have no colour.
                let coloured = tool == .pen || tool == .arrow || tool == .box
                HStack(spacing: 6) {
                    ForEach(colors, id: \.self) { col in
                        Button {
                            color = col
                        } label: {
                            Circle().fill(Color(nsColor: col)).frame(width: 16, height: 16)
                                .overlay(Circle().stroke(c.text.opacity(color == col ? 0.9 : 0.15), lineWidth: color == col ? 2 : 1).padding(-3))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 6)
                .opacity(coloured ? 1 : 0.25)
                .disabled(!coloured)
                Button {
                    if !marks.isEmpty { marks.removeLast(); rerender() }
                } label: {
                    ChipLabel(icon: "arrow.uturn.backward", title: "Undo", c: c)
                }
                .buttonStyle(.plain).keyboardShortcut("z", modifiers: .command).disabled(marks.isEmpty).opacity(marks.isEmpty ? 0.4 : 1)
            }
            canvas
            HStack(spacing: 8) {
                Chip(icon: "doc.on.doc", title: "Copy image", primary: true, c: c) {
                    guard let output else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([NSImage(cgImage: output, size: .zero)])
                    NSPasteboard.general.markOwn()
                    onDone("Marked-up image copied")
                }
                Chip(icon: "square.and.arrow.down", title: "Save copy", c: c) {
                    if let output, let u = ShareSafe.file(for: item, output, beside: true) {
                        NSWorkspace.shared.activateFileViewerSelecting([u]); onDone("Saved next to the original")
                    }
                }
                Text("Or drag the picture straight into Slack.").font(.system(size: 11)).foregroundStyle(c.soft)
                Spacer()
            }
        }
        .task(id: item.id) {
            guard let p = item.path else { return }
            let loaded = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
                    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
                else { return (nil, nil) }
                return (img, Markup.pixelated(img))
            }.value
            base = loaded.0; pixel = loaded.1; output = loaded.0
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            if let output {
                let size = fit(CGSize(width: output.width, height: output.height), in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: output, scale: 1).resizable().frame(width: size.width, height: size.height)
                    // The mark being drawn, previewed cheaply; the full-size render happens when the drag ends.
                    if let d = draft { DraftMark(mark: d, size: size).allowsHitTesting(false) }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(c.line))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            let a = norm(v.startLocation, size), b = norm(v.location, size)
                            var d = draft ?? Mark(tool: tool, a: a, b: b, color: color, points: [a])
                            d.b = b
                            if tool == .pen { d.points.append(b) }
                            draft = d
                        }
                        .onEnded { _ in
                            if let d = draft, d.tool == .pen ? d.points.count > 2 : hypot(d.a.x - d.b.x, d.a.y - d.b.y) > 0.01 {
                                marks.append(d); rerender()
                            }
                            draft = nil
                        }
                )
                .onDrag { url().flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                ProgressView().controlSize(.small).frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func rerender() {
        guard let base else { return }
        output = Markup.render(base, marks, pixel: pixel)
    }

    private func url() -> URL? { output.flatMap { ShareSafe.file(for: item, $0) } }

    private func norm(_ p: CGPoint, _ s: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x / max(s.width, 1), 0), 1), y: min(max(p.y / max(s.height, 1), 0), 1))
    }

    private func fit(_ s: CGSize, in box: CGSize) -> CGSize {
        let k = min(box.width / max(s.width, 1), box.height / max(s.height, 1))
        return CGSize(width: s.width * k, height: s.height * k)
    }
}

// The in-progress mark, in view coordinates.
private struct DraftMark: View {
    let mark: Mark
    let size: CGSize

    var body: some View {
        Canvas { ctx, _ in
            let a = CGPoint(x: mark.a.x * size.width, y: mark.a.y * size.height)
            let b = CGPoint(x: mark.b.x * size.width, y: mark.b.y * size.height)
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            let col = Color(nsColor: mark.color)
            switch mark.tool {
            case .blur: ctx.fill(Path(rect), with: .color(.gray.opacity(0.6)))
            case .highlight: ctx.fill(Path(rect), with: .color(Color(nsColor: Swatch.highlighter).opacity(0.45)))
            case .box: ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(col), lineWidth: 2.5)
            case .pen:
                let pts = mark.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                ctx.stroke(Path(Markup.penPath(pts)), with: .color(col), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            case .arrow:
                let (shaft, head) = Markup.arrowPath(from: a, to: b, width: 2.5)
                ctx.stroke(Path(shaft), with: .color(col), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                ctx.fill(Path(head), with: .color(col))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
