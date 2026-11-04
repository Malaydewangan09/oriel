import AppKit

// ⌃⌥T: drag a box over anything on screen and its text lands on the clipboard, and so on the shelf.
// Uses macOS's own selection tool (screencapture -i), the same crosshair as ⌘⇧4.
enum Grab {
    private static var running = false

    @MainActor
    static func run() {
        guard !running else { return }
        running = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sill-grab-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", file.path]  // interactive selection, no shutter sound
        p.terminationHandler = { _ in
            // Escape leaves no file. Reading text is slow, so it stays off the main thread.
            let text = FileManager.default.fileExists(atPath: file.path) ? FolderIndexer.readText(file) : nil
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async {
                running = false
                guard let text else { return }
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { NSSound.beep(); return }
                // Not marked as Sill's own, so the clipboard watcher saves it and the notch shows "Saved".
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clean, forType: .string)
            }
        }
        do { try p.run() } catch { running = false }
    }
}
