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

    /// Update the app's own Dock icon to match the current theme.
    private func updateAppIcon(for mode: AppearanceMode) {
        let iconName = mode == .dark ? "AppIcon-dark" : "AppIcon-light"
        guard let iconURL = Bundle.main.url(forResource: iconName, withExtension: "png"),
              let iconImage = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApp.applicationIconImage = iconImage
        NSApp.dockTile.display()
    }

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

            // Step 2: Restart Dock to refresh persistent icon cache
            let dk = Process()
            dk.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            dk.arguments = ["Dock"]
            try? dk.run()
            dk.waitUntilExit()

            // Step 3: Check for running apps (process memory cache issue)
            let appPaths = schemeList.map(\.appURL.path)
            let info = dock.analyze(appPaths: appPaths)
            let running = info.filter(\.isRunning)
            let pinned = info.filter(\.isPinned)

            if !running.isEmpty {
                // Running apps need to be restarted to clear process memory cache
                dock.prepareRestartAlert(runningApps: running.map {
                    ($0.appPath, $0.appName, $0.bundleID)
                })
            } else if !pinned.isEmpty {
                // Pinned-but-not-running: refresh by removing and re-adding to Dock
                for p in pinned {
                    dock.refreshDockPersistentItem(appPath: p.appPath)
                }
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
