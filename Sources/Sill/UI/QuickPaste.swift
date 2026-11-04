import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class PasteModel: ObservableObject {
    @Published var items: [Item] = []
    @Published var selected = 0
    @Published var queue: [Int64] = []
    @Published var note: String?

    func reload() {
        items = Store.shared.search(Query(), limit: 9)
        selected = min(selected, max(items.count - 1, 0))
        queue = queue.filter { id in items.contains { $0.id == id } }
    }

    func toggleQueue(_ item: Item) {
        if let i = queue.firstIndex(of: item.id) { queue.remove(at: i) } else { queue.append(item.id) }
    }
}

// Option-V: a numbered list of recent things at the cursor. Pick one and it is pasted where you were typing.
// Pasting for you needs Accessibility. Without it, the item is copied and you press Cmd-V yourself.
@MainActor
final class QuickPaste {
    static let shared = QuickPaste()
    private let model = PasteModel()
    private var panel: KeyPanel?
    private var monitor: Any?

    var isOpen: Bool { panel?.isVisible == true }

    // With a queue waiting, Option-V pastes the next one straight away. Otherwise it opens the list.
    func trigger() {
        if isOpen { close(); return }
        if let next = model.queue.first,
            let item = Store.shared.search(
                {
                    var q = Query(); q.ids = [next]; return q
                }(), limit: 1
            ).first
        {
            model.queue.removeFirst()
            paste(item)
            return
        }
        open()
    }

    private func open() {
        model.reload()
        model.note = nil
        let p = panel ?? makePanel()
        panel = p
        p.contentView?.layoutSubtreeIfNeeded()  // size from this open's rows, not the last one's
        p.setContentSize(p.contentView!.fittingSize)
        let size = p.frame.size
        let anchor = Self.caret() ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
        if origin.y < vis.minY { origin.y = anchor.maxY + 6 }
        origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
        p.setFrameOrigin(origin)
        p.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }

    private func makePanel() -> KeyPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: PasteList(model: model) { [weak self] item in self?.paste(item) })
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak p] _ in
            MainActor.assumeIsolated { p?.orderOut(nil) }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak p] e in
            guard let self, let p, p.isKeyWindow else { return e }
            let handled = MainActor.assumeIsolated { self.key(e) }
            return handled ? nil : e
        }
        return p
    }

    private func key(_ e: NSEvent) -> Bool {
        let items = model.items
        switch Int(e.keyCode) {
        case kVK_Escape: close()
        case kVK_DownArrow: model.selected = min(model.selected + 1, max(items.count - 1, 0))
        case kVK_UpArrow: model.selected = max(model.selected - 1, 0)
        case kVK_Space: if items.indices.contains(model.selected) { model.toggleQueue(items[model.selected]) }
        case kVK_Delete: model.queue.removeAll()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !model.queue.isEmpty { close(); trigger() } else if items.indices.contains(model.selected) { paste(items[model.selected]) }
        default:
            guard let n = Int(e.charactersIgnoringModifiers ?? ""), (1...items.count).contains(n) else { return false }
            paste(items[n - 1])
        }
        return true
    }

    private func paste(_ item: Item) {
        Self.write(item)
        guard AXIsProcessTrusted() else {
            // Without Accessibility Sill can't press Cmd-V for you, so say what happened instead of vanishing.
            model.note = "Copied. Press ⌘V to paste it."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                MainActor.assumeIsolated { if self?.model.note != nil { self?.close() } }
            }
            return
        }
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Self.pressCommandV() }
    }

    static func write(_ item: Item) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let p = item.path {
            let url = URL(fileURLWithPath: p)
            if item.kind == .screenshot, let img = NSImage(contentsOf: url) { pb.writeObjects([img]) } else { pb.writeObjects([url as NSURL]) }
        } else {
            pb.setString(item.body, forType: .string)
        }
        pb.markOwn()
    }

    private static func pressCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    // Where the text cursor is, when the app reports it. Many web-based apps don't, so the mouse is the fallback.
    private static func caret() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else { return nil }
        let el = focused as! AXUIElement
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
            let bounds
        else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &r), r.width >= 0, r.minX > 0 || r.minY > 0 else { return nil }
        // Accessibility uses a top-left origin on the main screen.
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: max(r.width, 1), height: r.height)
    }
}

struct PasteList: View {
    @ObservedObject var model: PasteModel
    var onPick: (Item) -> Void
    private let c = Palette.make(.next, dark: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SillMark().frame(width: 14, height: 14)
                Text("Paste from Sill").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("⌥V").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(c.soft)
            }
            .foregroundStyle(c.text).padding(.horizontal, 10).padding(.bottom, 4)
            if model.items.isEmpty {
                Text("Nothing copied yet.").font(.system(size: 12)).foregroundStyle(c.soft).padding(10)
            }
            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                row(i, item)
            }
            Divider().overlay(c.line).padding(.vertical, 4)
            Text(footer).font(.system(size: 11)).foregroundStyle(model.queue.isEmpty ? c.soft : c.accent).padding(.horizontal, 10)
            if let note = model.note {
                Label(note, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(c.accent)
                    .padding(.horizontal, 10).padding(.top, 4)
            }
            if !AXIsProcessTrusted() {
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                } label: {
                    Text("Allow Sill to paste for you →").font(.system(size: 11, weight: .semibold)).foregroundStyle(c.warm)
                }
                .buttonStyle(.plain).padding(.horizontal, 10).padding(.top, 4)
            }
        }
        .padding(10).frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 14).fill(c.shell.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(c.line))
    }

    private var footer: String {
        model.queue.isEmpty
            ? "1-9 to paste · Space to queue several · Esc to close"
            : "\(model.queue.count) queued · Return starts · ⌥V pastes the next one · ⌫ clears"
    }

    private func row(_ i: Int, _ item: Item) -> some View {
        let queued = model.queue.firstIndex(of: item.id)
        return HStack(spacing: 10) {
            Text("\(i + 1)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(c.soft).frame(width: 14)
            Image(systemName: item.lookIcon).font(.system(size: 11, weight: .semibold)).foregroundStyle(item.lookTint).frame(width: 16)
            Text(title(item)).font(.system(size: 12.5)).foregroundStyle(c.text).lineLimit(1)
            Spacer()
            if let queued { Text("queued \(queued + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(c.accent) }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(i == model.selected ? Color.white.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { onPick(item) }
    }

    private func title(_ item: Item) -> String {
        if item.secret != nil { return "\(item.secret ?? "Secret") ••••" }
        if let p = item.path { return (p as NSString).lastPathComponent }
        return item.body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
