import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var store: IconSchemeStore
    @EnvironmentObject private var appearance: AppearanceMonitor
    @EnvironmentObject private var applier: IconApplier
    @EnvironmentObject private var previewCache: IconPreviewCache

    var body: some View {
        VStack(alignment: .leading) {
            Button {
                showMainWindow()
            } label: {
                Label("打开 ChangeIcon", systemImage: "macwindow")
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button {
                Task {
                    await applier.applyIfNeeded(
                        schemes: store.schemes,
                        appearance: appearance.current,
                        force: true
                    )
                    previewCache.removeAll()
                }
            } label: {
                Label("立即应用\(appearance.current.title)图标", systemImage: "paintbrush.pointed.fill")
            }
            .disabled(applier.isApplying || store.schemes.isEmpty)

            Divider()

            // Quick scheme list
            if !store.schemes.isEmpty {
                Text("快捷方案")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)

                ForEach(store.schemes.prefix(8)) { scheme in
                    Button {
                        Task {
                            await applier.apply([scheme], appearance: appearance.current)
                            previewCache.removeAll()
                        }
                    } label: {
                        HStack {
                            Image(nsImage: previewCache.appIcon(for: scheme.appURL, size: NSSize(width: 18, height: 18)))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(scheme.appName)
                                .lineLimit(1)
                            Spacer()
                            if applier.isApplying {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            }
                        }
                    }
                    .disabled(applier.isApplying || !scheme.enabled || scheme.iconURL(for: appearance.current) == nil)
                }

                Divider()
            }

            Button {
                Task {
                    await applier.refreshIconCache(for: store.schemes.map(\.appURL))
                    previewCache.removeAll()
                }
            } label: {
                Label("刷新图标缓存", systemImage: "arrow.clockwise")
            }
            .disabled(applier.isApplying)

            Divider()

            // Status info
            VStack(alignment: .leading, spacing: 2) {
                Text("当前模式：\(appearance.current.title)")
                    .font(.caption)
                Text("\(store.schemes.filter(\.enabled).count) / \(store.schemes.count) 个方案已启用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)

            Divider()

            Button("退出 ChangeIcon") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .frame(minWidth: 220)
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
