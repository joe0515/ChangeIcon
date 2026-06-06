import SwiftUI
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.local.ChangeIcon", category: "App")

@main
struct ChangeIconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = IconSchemeStore()
    @StateObject private var appearance = AppearanceMonitor()
    @StateObject private var applier = IconApplier()
    @StateObject private var previewCache = IconPreviewCache()
    @StateObject private var suggestionEngine = IconSuggestionEngine()
    @StateObject private var userIconLibrary = UserIconLibrary.shared

    /// Permission detection and management
    @StateObject private var permissions = PermissionManager()
    @StateObject private var dock = DockManager()

    /// ⚠️ 已禁用: NSApp.applicationIconImage 在 macOS 上会泄漏到 NSStatusItem,
    /// 导致权限重启后菜单栏图标被覆盖为 AppIcon 而非 menubar-icon。
    /// Dock 图标改用 Info.plist 的 CFBundleIconFile (AppIcon.icns)。
    private func updateAppIcon(for mode: AppearanceMode) {}

    /// Handles appearance changes: apply icons, then handle Dock cache issues.
    /// The Dock has TWO independent icon caches that setIcon alone cannot clear:
    /// 1. Process memory cache — running apps must be restarted
    /// 2. Persistent item cache — pinned apps must be removed and re-added
    private func handleAppearanceChange(mode: AppearanceMode, store: IconSchemeStore, applier: IconApplier) {
        logger.info("Appearance changed to: \(mode.title, privacy: .public)")

        updateAppIcon(for: mode)
        let schemeList = store.schemes

        Task {
            // Step 1: Apply all icons to file metadata (immediate Finder/LaunchPad update)
            try? await Task.sleep(nanoseconds: 500_000_000)
            await applier.applyIfNeeded(schemes: schemeList, appearance: mode, force: true)

            // Step 2: Touch all app bundles so Dock's fsevents notices changes
            let attrs: [FileAttributeKey: Any] = [.modificationDate: Date()]
            for scheme in schemeList {
                try? FileManager.default.setAttributes(attrs, ofItemAtPath: scheme.appURL.path)
            }

            // Step 3: Clear all icon caches
            dock.clearGlobalIconCache()
            try? await Task.sleep(nanoseconds: 500_000_000)

            // Step 4: Restart Dock
            let dk = Process()
            dk.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            dk.arguments = ["Dock"]
            try? dk.run()
            dk.waitUntilExit()

            // Step 5: Wait for Dock to fully restart
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Step 6: Touch again + notify after restart
            for scheme in schemeList {
                NSWorkspace.shared.noteFileSystemChanged(scheme.appURL.path)
                try? FileManager.default.setAttributes(attrs, ofItemAtPath: scheme.appURL.path)
            }

            // Step 7: Force-refresh pinned apps
            let appPaths = schemeList.map(\.appURL.path)
            let info = dock.analyze(appPaths: appPaths)
            let running = info.filter(\.isRunning)
            let pinned = info.filter(\.isPinned)

            if !running.isEmpty {
                dock.prepareRestartAlert(runningApps: running.map {
                    ($0.appPath, $0.appName, $0.bundleID)
                })
            }
            for p in pinned {
                dock.forceDockIconRefresh(appPath: p.appPath, bundleID: p.bundleID)
            }
        }
    }

    private var shouldShowGuide: Bool {
        !permissions.userDismissed && !permissions.allGranted
    }

    var body: some Scene {
        WindowGroup("ChangeIcon", id: "main") {
            ZStack {
                if shouldShowGuide {
                    PermissionGuideView(permissions: permissions)
                } else {
                    mainContent
                }
            }
            .animation(.easeInOut(duration: 0.3), value: shouldShowGuide)
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                if let w = NSApp.windows.first(where: { $0.title.contains("ChangeIcon") }) {
                    w.makeKeyAndOrderFront(nil)
                }
            }
            .onAppear {
                permissions.checkAll()
                SharedAppState.shared.store = store
                SharedAppState.shared.appearance = appearance
                SharedAppState.shared.applier = applier
                SharedAppState.shared.previewCache = previewCache
            }
            .alert(dock.restartAlertTitle, isPresented: $dock.needsRestartAlert) {
                Button("立即重启") {
                    Task { await dock.restartAllQueuedApps() }
                }
                Button("稍后手动重启", role: .cancel) {
                    dock.restartApps.removeAll()
                }
            } message: {
                Text(dock.restartAlertMessage)
            }
            .onChange(of: permissions.allGranted) { _, granted in
                if granted { logger.info("All permissions granted — loading main UI") }
            }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("应用当前外观图标") {
                    Task {
                        await applier.applyIfNeeded(schemes: store.schemes, appearance: appearance.current, force: true)
                        previewCache.removeAll()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.schemes.isEmpty)

                Button("批量应用全部方案") {
                    Task {
                        await store.applyAll(appearance: appearance.current, applier: applier)
                        previewCache.removeAll()
                    }
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(store.schemes.isEmpty)

                Divider()

                Button("刷新图标缓存") {
                    Task {
                        await applier.refreshIconCache(for: store.schemes.map(\.appURL))
                        previewCache.removeAll()
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.schemes.isEmpty)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(permissions)
        }


    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        ContentView()
            .environmentObject(store)
            .environmentObject(appearance)
            .environmentObject(applier)
            .environmentObject(previewCache)
            .environmentObject(suggestionEngine)
            .environmentObject(userIconLibrary)
            .frame(minWidth: 960, minHeight: 660)
            .task {
                logger.info("Initial appearance: \(appearance.current.title, privacy: .public)")
                updateAppIcon(for: appearance.current)
                await applier.applyIfNeeded(schemes: store.schemes, appearance: appearance.current)
            }
            .onChange(of: appearance.current) { _, mode in
                handleAppearanceChange(mode: mode, store: store, applier: applier)
            }
            .onReceive(NotificationCenter.default.publisher(for: .dockIconDropped)) { notification in
                guard let urls = notification.userInfo?["urls"] as? [URL],
                      let iconURL = urls.first else { return }
                Task {
                    let enabledSchemes = store.schemes.filter { $0.enabled }
                    if enabledSchemes.count == 1, let scheme = enabledSchemes.first {
                        store.setIcon(iconURL, for: scheme, mode: appearance.current)
                        await applier.apply([scheme], appearance: appearance.current)
                        previewCache.removeAll()
                    } else if !enabledSchemes.isEmpty {
                        for scheme in enabledSchemes {
                            store.setIcon(iconURL, for: scheme, mode: appearance.current)
                        }
                        await applier.apply(enabledSchemes, appearance: appearance.current)
                        previewCache.removeAll()
                    }
                }
            }
    }
}
