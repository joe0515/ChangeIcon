import SwiftUI
import AppKit

@main
struct ChangeIconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = IconSchemeStore()
    @StateObject private var appearance = AppearanceMonitor()
    @StateObject private var applier = IconApplier()
    @StateObject private var previewCache = IconPreviewCache()
    @StateObject private var suggestionEngine = IconSuggestionEngine()

    private func updateAppIcon(for mode: AppearanceMode) {
        let iconName = mode == .dark ? "AppIcon-dark" : "AppIcon-light"
        guard let iconURL = Bundle.main.url(forResource: iconName, withExtension: "png"),
              let iconImage = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApp.applicationIconImage = iconImage
        NSApp.dockTile.display()
    }

    var body: some Scene {
        WindowGroup("ChangeIcon", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(appearance)
                .environmentObject(applier)
                .environmentObject(previewCache)
                .environmentObject(suggestionEngine)
                .frame(minWidth: 960, minHeight: 660)
                .task {
                    updateAppIcon(for: appearance.current)
                    await applier.applyIfNeeded(
                        schemes: store.schemes,
                        appearance: appearance.current
                    )
                }
                .onChange(of: appearance.current) { _, mode in
                    updateAppIcon(for: mode)
                    Task {
                        await applier.applyIfNeeded(
                            schemes: store.schemes,
                            appearance: mode,
                            force: true
                        )
                    }
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
                            // Apply to all enabled schemes
                            for scheme in enabledSchemes {
                                store.setIcon(iconURL, for: scheme, mode: appearance.current)
                            }
                            await applier.apply(enabledSchemes, appearance: appearance.current)
                            previewCache.removeAll()
                        }
                    }
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("应用当前外观图标") {
                    Task {
                        await applier.applyIfNeeded(
                            schemes: store.schemes,
                            appearance: appearance.current,
                            force: true
                        )
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
        }

        MenuBarExtra("ChangeIcon", systemImage: "paintbrush.pointed") {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(appearance)
                .environmentObject(applier)
                .environmentObject(previewCache)
        }
    }
}
