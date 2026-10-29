import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private var searchPanel: KeyPanel?
    private var settingsWindow: NSWindow?
    private let clipboard = ClipboardWatcher()
    private let folders = FolderIndexer()
    private let shelf = NotchShelf()
    private var shelfKey: Hotkey?
    private var grabKey: Hotkey?
    private var pasteKey: Hotkey?

    func applicationDidFinishLaunching(_ note: Notification) {
        Pref.register()
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.editMenu()
        installStatusItem()
        startCapture()
        shelf.install()
        shelfKey = Hotkey { [weak self] in MainActor.assumeIsolated { self?.toggleShelf() } }
        grabKey = Hotkey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey | controlKey)) { MainActor.assumeIsolated { Grab.run() } }
        syncPasteKey()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPasteKey() }
        }
        scheduleMaintenance()
    }

    private func installStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = Self.menuBarBird()
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open shelf  (⌃⌥Space or hover the notch)", action: #selector(toggleShelf), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Grab text from screen  (⌃⌥T)", action: #selector(grabText), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quick search list", action: #selector(toggleSearch), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Oriel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = $0.action == #selector(NSApplication.terminate(_:)) ? nil : self }
        status.menu = menu
    }

    // Demo mode (ORIEL_DEMO=1) keeps everything already in your folders out of a recording. New files still show up.
    private func startCapture() {
        clipboard.start()
        folders.start(since: ProcessInfo.processInfo.environment["ORIEL_DEMO"] == "1" ? Date() : nil)
    }

    // Purging applies the history length and forgets expired secrets, which live two minutes.
    private func scheduleMaintenance() {
        let purge = {
            DispatchQueue.global(qos: .utility).async { Store.shared.purge(keepDays: UserDefaults.standard.integer(forKey: Pref.keepDays)) }
        }
        let refresh = { DispatchQueue.global(qos: .utility).async { Vocabulary.shared.refresh() } }
        purge()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in purge() }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in refresh() }
    }

    // Option-V is only claimed while Quick paste is on, so it types √ again when turned off.
    private func syncPasteKey() {
        let on = UserDefaults.standard.bool(forKey: Pref.quickPaste)
        if on, pasteKey == nil {
            pasteKey = Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey)) { MainActor.assumeIsolated { QuickPaste.shared.trigger() } }
        } else if !on {
            pasteKey = nil
        }
    }

    @objc func toggleShelf() { shelf.toggle() }

    @objc func grabText() { Grab.run() }

    @objc func showSettings() {
        let w = settingsWindow ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Oriel Settings"
        w.contentView = NSHostingView(rootView: SettingsView())
        w.setContentSize(w.contentView?.fittingSize ?? .zero)
        w.isReleasedWhenClosed = false
        w.center()
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc func toggleSearch() {
        if let searchPanel, searchPanel.isVisible { searchPanel.close(); return }
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.contentView = NSHostingView(rootView: SearchView(model: SearchModel(), onClose: { [weak p] in p?.close() }))
        p.setContentSize(p.contentView?.fittingSize ?? .zero)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - f.height * 0.18))
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak p] _ in
            MainActor.assumeIsolated { p?.close() }
        }
        searchPanel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    // The Oriel bird as a template image, so macOS tints it like every other menu bar icon.
    private static func menuBarBird() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(OrielMark().path(in: rect.insetBy(dx: 0.5, dy: 0.5)).cgPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Oriel"
        return img
    }

    // Never shown for a menu bar app, but text fields only get Cmd-C, V, X, A and Z through these key equivalents.
    private static func editMenu() -> NSMenu {
        let main = NSMenu()
        let holder = NSMenuItem()
        main.addItem(holder)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        holder.submenu = edit
        return main
    }
}
