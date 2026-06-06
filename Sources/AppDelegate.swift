import AppKit
import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.local.ChangeIcon", category: "AppDelegate")

@MainActor
final class SharedAppState {
    static let shared = SharedAppState()
    weak var store: IconSchemeStore?
    weak var appearance: AppearanceMonitor?
    weak var applier: IconApplier?
    weak var previewCache: IconPreviewCache?
    var openWindowAction: ((String) -> Void)?
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var activityToken: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private var menu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("ChangeIcon started")

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .userInitiated],
            reason: "Monitoring system appearance changes"
        )

        // Defer status item creation to next runloop cycle.
        // After a permissions-triggered restart, macOS may still be cleaning up
        // the previous process's menu bar slot; yielding avoids a race.
        DispatchQueue.main.async { [weak self] in
            self?.setupStatusItem()
        }

        // Always-active observer for main window reopening (survives window close)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenMainWindow),
            name: .openMainWindow,
            object: nil
        )
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.isVisible = true

        if let iconPath = Bundle.main.path(forResource: "menubar-icon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            icon.isTemplate = true
            icon.size = NSSize(width: 18, height: 18)
            statusItem?.button?.image = icon
            statusItem?.button?.imagePosition = .imageOnly
            logger.info("Status item created with menubar-icon.icns")
        } else {
            // Fallback: try PNG
            if let pngPath = Bundle.main.path(forResource: "menubar-icon", ofType: "png"),
               let pngIcon = NSImage(contentsOfFile: pngPath) {
                pngIcon.isTemplate = true
                pngIcon.size = NSSize(width: 18, height: 18)
                statusItem?.button?.image = pngIcon
                statusItem?.button?.imagePosition = .imageOnly
                logger.warning("Loaded menubar-icon.png as fallback")
            } else {
                logger.error("Failed to load menubar-icon (icns/png), status item created without icon")
            }
        }

        menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = SharedAppState.shared
        guard let store = s.store, let appearance = s.appearance,
              let applier = s.applier, let previewCache = s.previewCache else {
            menu.addItem(NSMenuItem(title: "加载中...", action: nil, keyEquivalent: ""))
            return
        }

        let modeTitle = appearance.current.title
        let enabledSchemes = store.schemes.filter(\.enabled)

        // Open main window
        menu.addItem(NSMenuItem(title: "打开 ChangeIcon", action: #selector(openMainWindow), keyEquivalent: "o"))
        menu.addItem(.separator())

        // Apply current icon
        let applyItem = NSMenuItem(title: "立即应用\(modeTitle)图标", action: #selector(applyCurrentIcons), keyEquivalent: "")
        applyItem.isEnabled = !enabledSchemes.isEmpty && !applier.isApplying
        menu.addItem(applyItem)
        menu.addItem(.separator())

        // Quick scheme list
        if !enabledSchemes.isEmpty {
            let headerItem = NSMenuItem(title: "快捷方案", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            menu.addItem(headerItem)
            for scheme in enabledSchemes.prefix(8) {
                let item = NSMenuItem(title: scheme.appName, action: #selector(applyScheme(_:)), keyEquivalent: "")
                item.representedObject = scheme.id.uuidString
                item.isEnabled = scheme.iconURL(for: appearance.current) != nil && !applier.isApplying
                let appIcon = previewCache.appIcon(for: scheme.appURL, size: NSSize(width: 16, height: 16))
                appIcon.isTemplate = false
                item.image = appIcon
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // Refresh cache
        let refreshItem = NSMenuItem(title: "刷新图标缓存", action: #selector(refreshCache), keyEquivalent: "")
        refreshItem.isEnabled = !applier.isApplying
        menu.addItem(refreshItem)
        menu.addItem(.separator())

        // Status info
        let statusInfo = NSMenuItem(title: "当前模式：\(modeTitle)", action: nil, keyEquivalent: "")
        statusInfo.isEnabled = false
        menu.addItem(statusInfo)
        let countInfo = NSMenuItem(title: "\(enabledSchemes.count) / \(store.schemes.count) 个方案已启用", action: nil, keyEquivalent: "")
        countInfo.isEnabled = false
        menu.addItem(countInfo)
        menu.addItem(.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "退出 ChangeIcon", action: #selector(quitApp), keyEquivalent: "q"))
    }

    @objc private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let w = NSApp.windows.first(where: { $0.title.contains("ChangeIcon") }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            // Window was closed — use SwiftUI to recreate it
            SharedAppState.shared.openWindowAction?("main")
        }
    }

    @objc private func handleOpenMainWindow(_ notification: Notification) {
        // Safety net: catches .openMainWindow when SwiftUI onReceive may be torn down
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.title.contains("ChangeIcon") }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            SharedAppState.shared.openWindowAction?("main")
        }
    }

    @objc private func applyCurrentIcons() {
        guard let s = SharedAppState.shared.store,
              let a = SharedAppState.shared.appearance,
              let apl = SharedAppState.shared.applier else { return }
        Task { await apl.applyIfNeeded(schemes: s.schemes, appearance: a.current, force: true) }
    }

    @objc private func applyScheme(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let s = SharedAppState.shared.store,
              let a = SharedAppState.shared.appearance,
              let apl = SharedAppState.shared.applier,
              let scheme = s.schemes.first(where: { $0.id == id }) else { return }
        Task { await apl.apply([scheme], appearance: a.current) }
    }

    @objc private func refreshCache() {
        guard let s = SharedAppState.shared.store,
              let apl = SharedAppState.shared.applier,
              let pc = SharedAppState.shared.previewCache else { return }
        Task { await apl.refreshIconCache(for: s.schemes.map(\.appURL)); pc.removeAll() }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let w = NSApp.windows.first(where: { $0.title.contains("ChangeIcon") }) { w.makeKeyAndOrderFront(nil) }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        let iconURLs = urls.filter { ["icns", "png", "jpg", "jpeg", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
        guard !iconURLs.isEmpty else { return }
        NotificationCenter.default.post(name: .dockIconDropped, object: nil, userInfo: ["urls": iconURLs])
        NSApp.reply(toOpenOrPrint: .success)
    }
}

extension Notification.Name {
    static let dockIconDropped = Notification.Name("ChangeIcon.dockIconDropped")
    static let openMainWindow = Notification.Name("ChangeIcon.openMainWindow")
}
