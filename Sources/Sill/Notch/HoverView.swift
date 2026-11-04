import AppKit

final class HoverView: NSView {
    var onEnter: (@MainActor () -> Void)?
    var onDragHover: (@MainActor (Bool) -> Void)?
    var onDrop: (@MainActor ([URL], String?) -> Void)?

    // Only say yes to what can actually be kept. A refused screenshot thumbnail falls back to saving on the Desktop.
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        guard Self.canKeep(s.draggingPasteboard) else { return [] }
        MainActor.assumeIsolated { onDragHover?(true) }
        return .copy
    }

    private static func canKeep(_ pb: NSPasteboard) -> Bool {
        let types = Set(pb.types ?? [])
        let promise = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        if types.contains(.fileURL) || !types.isDisjoint(with: promise) || types.contains(.png) || types.contains(.tiff) { return true }
        return !(pb.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    override func draggingExited(_ s: NSDraggingInfo?) { MainActor.assumeIsolated { onDragHover?(false) } }
    override func draggingEnded(_ s: NSDraggingInfo) { MainActor.assumeIsolated { onDragHover?(false) } }

    // Where dropped things that aren't files yet get saved: the screenshot thumbnail, an image from a web page.
    static let dropFolder: URL = {
        let dir = Store.folder.appendingPathComponent("Dropped", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let pb = s.draggingPasteboard
        // 1. Real files, from Finder or the Desktop.
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { MainActor.assumeIsolated { onDrop?(urls, nil) }; return true }
        // 2. File promises: the floating screenshot thumbnail and many apps hand over a file that is written on drop.
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            for r in promises {
                r.receivePromisedFiles(atDestination: Self.dropFolder, options: [:], operationQueue: .main) { [weak self] url, error in
                    guard error == nil else { return }
                    MainActor.assumeIsolated { self?.onDrop?([url], nil) }
                }
            }
            return true
        }
        // 3. Image data with no file behind it, like a picture dragged out of a web page.
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        {
            let name =
                "Dropped image "
                + Date().formatted(.dateTime.year().month().day().hour().minute().second()).replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: ".") + ".png"
            let url = Self.dropFolder.appendingPathComponent(name)
            if (try? png.write(to: url)) != nil { MainActor.assumeIsolated { onDrop?([url], nil) }; return true }
        }
        // 4. Plain text, never an empty string.
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MainActor.assumeIsolated { onDrop?([], text) }; return true
        }
        return false
    }

    var drawsNotch = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }  // NotchShape draws from the top edge down

    override func draw(_ dirtyRect: NSRect) {
        guard drawsNotch, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.addPath(NotchShape(ear: 6, bottom: 8).path(in: bounds).cgPath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
    }
    private var dwell: Timer?

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    // A short dwell so passing the cursor over the top edge doesn't pop the shelf open.
    override func mouseEntered(with event: NSEvent) {
        dwell = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnter?() }
        }
    }

    override func mouseExited(with event: NSEvent) { dwell?.invalidate() }
}
