import AppKit
import Quartz
import SwiftUI

// Owns the notch window and the invisible hover target that sits over the notch.
@MainActor
final class NotchShelf {
    private let model = ShelfModel()
    private let state = NotchState()
    private var window: KeyPanel?
    private var hover: NSPanel?
    private var closing: DispatchWorkItem?
    private var previousApp: NSRunningApplication?

    private var screen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }

    func install() {
        placeHoverTarget()
        window = makeWindow()  // built up front so the first peek doesn't pay for it
        // Plugging in a display, closing the lid or changing resolution moves the notch, or takes it away.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.close()
                self?.placeHoverTarget()
            }
        }
        NotificationCenter.default.addObserver(forName: .orielCaught, object: nil, queue: .main) { [weak self] note in
            let item = note.userInfo?["item"] as? Item
            MainActor.assumeIsolated { self?.caught(item) }
        }
        // Switching design while open resizes the panel straight away.
        design = Design.current
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.designChanged() }
        }
    }

    private var design = Design.current

    private func designChanged() {
        let now = Design.current
        guard now != design else { return }
        design = now
        guard isOpen, let screen, let w = window else { return }
        measure(screen)
        let f = screen.frame, width = state.full.width + 28
        w.setFrame(
            NSRect(x: f.midX - width / 2, y: f.maxY - state.full.height, width: width, height: state.full.height), display: true, animate: false)
    }

    // Only fresh catches peek. Files picked up from earlier days during the first scan stay quiet.
    private func caught(_ item: Item?) {
        guard let item, Date().timeIntervalSince(item.ts) < 90 else { return }
        model.collectIfOn(item)
        // The shelf reloads when it opens, so a closed one is left alone: re-rendering it hidden held up the peek.
        if isOpen { model.didCatch(); return }
        if UserDefaults.standard.bool(forKey: Pref.peek) { peek(item) }
    }

    private var peekWork: DispatchWorkItem?

    // A file dragged over the notch: show where to drop it.
    private func dragHover(_ on: Bool) {
        guard !isOpen, let screen else { return }
        if on {
            let w = window ?? makeWindow()
            window = w
            if !w.isVisible {
                let f = screen.frame, width = state.full.width + 28
                w.setFrame(NSRect(x: f.midX - width / 2, y: f.maxY - state.full.height, width: width, height: state.full.height), display: true)
                w.ignoresMouseEvents = true  // the drop has to reach the notch target underneath
                w.orderFrontRegardless()
            }
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { state.dropHint = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { state.dropHint = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.state.expanded, !self.state.dropHint, self.state.peek == nil else { return }
                self.window?.orderOut(nil)
            }
        }
    }

    // Dropped files and text are kept on the shelf and pinned, so they stay until you take them out.
    func keep(_ urls: [URL], text: String?) {
        state.dropHint = false
        let now = Date()
        for var u in urls.prefix(20) {
            // Files in temporary folders (the screenshot thumbnail's, for one) vanish after the drag: keep our own copy.
            if u.path.hasPrefix(NSTemporaryDirectory()) || u.path.contains("/TemporaryItems/") || u.path.contains("/var/folders/") {
                let dest = HoverView.dropFolder.appendingPathComponent(u.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                guard (try? FileManager.default.copyItem(at: u, to: dest)) != nil else { continue }
                u = dest
            }
            if let id = Store.shared.add(
                kind: .download, ts: now, app: "Oriel", title: u.lastPathComponent, body: "", path: u.path,
                source: Item.notchSource, fingerprint: "drop:\(u.path):\(now.timeIntervalSince1970)")
            {
                Store.shared.setPinned(id, true)
            }
        }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
            let id = Store.shared.add(kind: .copy, ts: now, app: "Oriel", title: "", body: text, fingerprint: copyFingerprint(text))
        {
            Store.shared.setPinned(id, true)
        }
        model.reload()
    }

    private func peek(_ item: Item) {
        guard let screen else { return }
        let w = window ?? makeWindow()
        window = w
        if !w.isVisible {
            let f = screen.frame, width = state.full.width + 28
            w.setFrame(NSRect(x: f.midX - width / 2, y: f.maxY - state.full.height, width: width, height: state.full.height), display: true)
            w.ignoresMouseEvents = true  // the big transparent window must not swallow clicks while only the peek shows
            w.orderFrontRegardless()
        }
        closing?.cancel()
        withAnimation(.spring(duration: 0.28, bounce: 0.15)) { state.peek = item }
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak w] in
            guard let self, !self.state.expanded else { return }
            withAnimation(.spring(duration: 0.35, bounce: 0)) { self.state.peek = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if !self.state.expanded && self.state.peek == nil { w?.orderOut(nil) } }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func measure(_ screen: NSScreen) {
        let f = screen.frame
        let menuBar = f.maxY - screen.visibleFrame.maxY
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.notch = CGSize(width: f.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            state.notch = CGSize(width: 180, height: max(menuBar, 24))
        }
        state.topInset = max(screen.safeAreaInsets.top, menuBar) + 6
        let next = Design.current != .classic
        state.full = CGSize(width: min(f.width - 160, 1040), height: (next ? min(f.height * 0.52, 500) : 300) + state.topInset)
    }

    var isOpen: Bool { window?.isVisible == true && state.expanded }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard let screen else { return }
        closing?.cancel()
        measure(screen)
        if !model.text.isEmpty { model.text = "" }  // setting it reloads, so only when needed
        model.detail = ClaudeAgent.shared.unseen ? .claude : nil
        let w = window ?? makeWindow()
        window = w
        w.ignoresMouseEvents = false
        peekWork?.cancel()
        state.peek = nil
        let f = screen.frame
        let width = state.full.width + 28
        w.setFrame(NSRect(x: f.midX - width / 2, y: f.maxY - state.full.height, width: width, height: state.full.height), display: true)
        state.expanded = false
        if let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            // Refreshed after the window is up: the content is still hidden, so this costs no visible time.
            self.model.refreshStacks()
            self.model.reload()
            withAnimation(.spring(duration: 0.24, bounce: 0)) { self.state.expanded = true }
        }
    }

    func close() {
        guard let w = window, w.isVisible else { return }
        withAnimation(.spring(duration: 0.2, bounce: 0)) { state.expanded = false }
        // Hand focus back to the app you were in, so Cmd-V right after copying lands there.
        if NSApp.isActive, !NSApp.windows.contains(where: { $0 !== w && $0.isVisible && $0.canBecomeMain }) {
            previousApp?.activate()
        }
        let work = DispatchWorkItem { [weak w] in w?.orderOut(nil) }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func makeWindow() -> KeyPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)  // above the menu bar, so it can meet the notch
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(
            rootView: NotchContainer(
                state: state, model: model, onClose: { [weak self] in self?.close() },
                onDrop: { [weak self] urls, text in self?.keep(urls, text: text) }))
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if !Peek.shared.isShowing { self?.close() } }
        }
        // Cmd-key presses in a text field go to key equivalents first, so onKeyPress never sees Cmd+Y.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak p] e in
            guard let self, e.modifierFlags.contains(.command), p?.isKeyWindow == true || Peek.shared.isShowing else { return e }
            if e.keyCode == 36, p?.isKeyWindow == true { MainActor.assumeIsolated { self.model.openDetail() }; return nil }
            // Cmd-Delete deletes the selected item, as in Finder. While a search is typed it keeps clearing the line instead.
            if e.keyCode == 51, p?.isKeyWindow == true, MainActor.assumeIsolated({ self.model.text.isEmpty }) {
                MainActor.assumeIsolated { if let item = self.model.current { self.model.delete(item) } }
                return nil
            }
            guard e.charactersIgnoringModifiers == "y" else { return e }
            MainActor.assumeIsolated {
                if Peek.shared.isShowing {
                    QLPreviewPanel.shared().orderOut(nil); p?.makeKey()
                } else if let item = self.model.current {
                    self.model.quickLook(item)
                }
            }
            return nil
        }
        return p
    }

    private func placeHoverTarget() {
        hover?.orderOut(nil)
        hover = nil
        guard let screen else { return }
        measure(screen)
        installHoverTarget(on: screen)
    }

    // An invisible window exactly over the notch. Hovering it opens the shelf. No permissions involved.
    // A screen without a notch gets a drawn one, so there is something to hover.
    private func installHoverTarget(on screen: NSScreen) {
        let f = screen.frame
        let rect = NSRect(x: f.midX - state.notch.width / 2, y: f.maxY - state.notch.height, width: state.notch.width, height: state.notch.height)
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = HoverView(frame: NSRect(origin: .zero, size: rect.size))
        view.drawsNotch = screen.safeAreaInsets.top == 0
        view.onEnter = { [weak self] in self?.open() }
        view.onDragHover = { [weak self] on in self?.dragHover(on) }
        view.onDrop = { [weak self] urls, text in self?.keep(urls, text: text) }
        view.registerForDraggedTypes(
            [.fileURL, .png, .tiff, .string] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        p.contentView = view
        p.orderFrontRegardless()
        hover = p
    }
}
