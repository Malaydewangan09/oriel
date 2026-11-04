import AppKit
import PDFKit
import Vision

// Indexes downloads and screenshots, reading text out of images and PDFs on this Mac.
final class FolderIndexer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sill.indexer", qos: .utility)
    private var seen = Set<String>()
    private var watchers: [DispatchSourceFileSystemObject] = []

    static var screenshotFolder: URL {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        return custom.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    // `since` keeps everything older out, e.g. demo mode only picks up files made after launch.
    func start(days: Int = 14, since: Date? = nil) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let scan = { [weak self] in
            self?.scan(downloads, kind: .download, days: days, since: since)
            self?.scan(Self.screenshotFolder, kind: .screenshot, days: days, since: since)
        }
        queue.async(execute: scan)
        // The folders are watched so a new file shows within a second. The timer catches a moved screenshot location.
        for folder in [downloads, Self.screenshotFolder] { watch(folder, then: scan) }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.queue.async(execute: scan) }
    }

    // Fires when an entry is added to or renamed in the folder. The short wait lets the writer finish the file.
    private func watch(_ folder: URL, then scan: @escaping () -> Void) {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in self?.queue.asyncAfter(deadline: .now() + 0.4, execute: scan) }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers.append(source)
    }

    private func scan(_ folder: URL, kind: Kind, days: Int, since: Date?) {
        let cutoff = max(since ?? .distantPast, Date().addingTimeInterval(-Double(days) * 86_400))
        let keys: [URLResourceKey] = [.contentModificationDateKey, .addedToDirectoryDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return }
        for url in files where !seen.contains(url.path) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let date = v.addedToDirectoryDate ?? v.contentModificationDate ?? Date()
            guard date > cutoff else { continue }
            // Browsers write here under a temporary name, then rename the finished file, which is caught then.
            if ["crdownload", "part", "partial", "download", "tmp"].contains(url.pathExtension.lowercased()) { continue }
            let name = url.lastPathComponent
            let isShot = kind == .screenshot
            if isShot && !(name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot") || name.hasPrefix("CleanShot")) { continue }
            seen.insert(url.path)
            let text = Self.readText(url)
            Store.shared.add(
                kind: kind, ts: date, app: nil, title: name, body: text, path: url.path, source: Self.downloadedFrom(url),
                fingerprint: fingerprint(kind.rawValue, url.path, String(date.timeIntervalSince1970)))
        }
    }

    static func readText(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "tiff":
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "" }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: img).perform([req])
            return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        case "pdf":
            guard let doc = PDFDocument(url: url) else { return "" }
            return (0..<min(doc.pageCount, 5)).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n").prefix(20_000).description
        case "txt", "md", "csv", "json", "log":
            return (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(20_000)) } ?? ""
        default:
            return ""
        }
    }

    // The website or app a download came from, from the file's "Where from" metadata.
    static func downloadedFrom(_ url: URL) -> String? {
        let size = getxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { getxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, size, 0, 0) }
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return nil }
        for s in list.reversed() { if let host = URL(string: s)?.host { return host.replacingOccurrences(of: "www.", with: "") } }
        return nil
    }
}
