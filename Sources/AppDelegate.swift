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

        setupStatusItem()

        // Re-apply icon after delays — defends against system-level overrides
        // during permissions-triggered app relaunch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshStatusItemIcon()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshStatusItemIcon()
        }

        // Always-active observer for main window reopening (survives window close)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenMainWindow),
            name: .openMainWindow,
            object: nil
        )

        // Listen for icon refresh requests from updateAppIcon
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRefreshStatusItemIcon),
            name: .refreshStatusItemIcon,
            object: nil
        )
    }

    /// Re-applies the menu bar icon to the status item.
    /// Called on launch and on any event that might reset the button image.
    private func refreshStatusItemIcon() {
        guard let button = statusItem?.button else { return }
        let (icon, source) = loadMenuBarIcon()
        icon.isTemplate = true
        icon.size = NSSize(width: 18, height: 18)
        button.image = icon
        button.imagePosition = .imageOnly
        logger.debug("Status item icon refreshed from \(source, privacy: .public)")
    }

    @objc private func handleRefreshStatusItemIcon() {
        // Called from updateAppIcon after setting NSApp.applicationIconImage,
        // which may have propagated to NSStatusItem
        refreshStatusItemIcon()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // After a permissions-triggered restart, SwiftUI's .task block may
        // call updateAppIcon() after we receive applicationDidBecomeActive.
        // A 1-second delay ensures our refresh runs AFTER updateAppIcon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshStatusItemIcon()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.isVisible = true

        let (icon, source) = loadMenuBarIcon()
        icon.isTemplate = true
        icon.size = NSSize(width: 18, height: 18)
        statusItem?.button?.image = icon
        statusItem?.button?.imagePosition = .imageOnly
        logger.info("Status item created from \(source, privacy: .public) (\(Int(icon.size.width))x\(Int(icon.size.height)))")

        menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    /// Load the menu bar icon. Tries multiple approaches to ensure reliability:
    ///
    /// 1. Bundle PNG (single-representation, most predictable)
    /// 2. Bundle ICNS (multi-representation fallback)
    /// 3. Programmatic SF Symbol (guaranteed to render)
    ///
    /// Returns the image and a source label for logging.
    private func loadMenuBarIcon() -> (NSImage, String) {
        // 1. Try PNG from bundle Resources
        if let pngPath = Bundle.main.path(forResource: "menubar-icon", ofType: "png") {
            logger.debug("Bundle PNG path: \(pngPath, privacy: .public)")
            if let png = NSImage(contentsOfFile: pngPath), png.size.width > 0 {
                return (png, "menubar-icon.png")
            }
        } else {
            logger.warning("Bundle.main.path(forResource: menubar-icon.png) returned nil")
        }

        // 2. Try ICNS from bundle Resources
        if let icnsPath = Bundle.main.path(forResource: "menubar-icon", ofType: "icns") {
            logger.debug("Bundle ICNS path: \(icnsPath, privacy: .public)")
            if let icns = NSImage(contentsOfFile: icnsPath), icns.size.width > 0 {
                return (icns, "menubar-icon.icns")
            }
        } else {
            logger.warning("Bundle.main.path(forResource: menubar-icon.icns) returned nil")
        }

        // 3. Direct file access — bypass Bundle API entirely
        if let resourceURL = Bundle.main.resourceURL {
            let directPNG = resourceURL.appendingPathComponent("menubar-icon.png")
            let directICNS = resourceURL.appendingPathComponent("menubar-icon.icns")

            if FileManager.default.fileExists(atPath: directPNG.path),
               let png = NSImage(contentsOf: directPNG),
               png.size.width > 0 {
                logger.warning("Loaded via direct path: \(directPNG.path, privacy: .public)")
                return (png, "direct: menubar-icon.png")
            }

            if FileManager.default.fileExists(atPath: directICNS.path),
               let icns = NSImage(contentsOf: directICNS),
               icns.size.width > 0 {
                logger.warning("Loaded via direct path: \(directICNS.path, privacy: .public)")
                return (icns, "direct: menubar-icon.icns")
            }

            // Log what's actually in the resources directory for diagnostics
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: resourceURL.path) {
                let icons = contents.filter { $0.contains("menubar") || $0.contains("AppIcon") }
                logger.warning("Resources directory menubar/AppIcon files: \(icons.joined(separator: ", "), privacy: .public)")
            }
        }

        // 4. Ultimate fallback: SF Symbol — always available, never fails
        if let symbol = NSImage(
            systemSymbolName: "arrow.triangle.swap",
            accessibilityDescription: "ChangeIcon"
        ) {
            logger.warning("Using SF Symbol fallback — menubar-icon resources not found")
            symbol.isTemplate = true
            return (symbol, "SF Symbol")
        }

        // 5. True last resort
        logger.error("All icon sources failed — empty placeholder")
        return (NSImage(size: NSSize(width: 18, height: 18)), "empty placeholder")
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
    static let refreshStatusItemIcon = Notification.Name("ChangeIcon.refreshStatusItemIcon")
}
