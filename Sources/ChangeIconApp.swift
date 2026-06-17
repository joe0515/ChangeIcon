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
    @StateObject private var sudoersManager = SudoersManager.shared

    private var shouldShowGuide: Bool {
        !permissions.userDismissed && !permissions.allGranted
    }

    var body: some Scene {
        WindowGroup("ChangeIcon", id: "main") {
            ZStack {
                if shouldShowGuide {
                    PermissionGuideView(permissions: permissions, sudoersManager: sudoersManager)
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
            .modifier(OpenWindowBridge())
            .onAppear {
                permissions.checkAll()
                SharedAppState.shared.store = store
                SharedAppState.shared.appearance = appearance
                SharedAppState.shared.applier = applier
                SharedAppState.shared.previewCache = previewCache
                SharedAppState.shared.dock = dock
                Task { await sudoersManager.checkConfiguration() }
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
                .environmentObject(sudoersManager)
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
                await applier.applyIfNeeded(schemes: store.schemes, appearance: appearance.current)
            }
            // Appearance changes are handled by AppDelegate.onAppearanceChanged()
            // to avoid double Dock restart (AppDelegate + this onChange)
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

// MARK: - OpenWindow Bridge

/// Captures the SwiftUI `openWindow` environment action and stores it on
/// `SharedAppState` so AppDelegate can recreate the main window after it
/// has been closed (e.g. Dock icon click).
private struct OpenWindowBridge: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onAppear {
                SharedAppState.shared.openWindowAction = { id in
                    openWindow(id: id)
                }
            }
    }
}
