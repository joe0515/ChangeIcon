import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: IconSchemeStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var statusText = ""

    var body: some View {
        Form {
            Toggle("登录时启动", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    setLaunchAtLogin(enabled)
                }

            Text("自动切换需要 ChangeIcon 保持运行。登录时启动可以让浅色和深色模式切换更及时。")
                .foregroundStyle(.secondary)
                .font(.callout)

            if !statusText.isEmpty {
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Divider()

            LabeledContent("已保存方案") {
                Text("\(store.schemes.count)")
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                statusText = "已设置为登录时启动。"
            } else {
                try SMAppService.mainApp.unregister()
                statusText = "已取消登录时启动。"
            }
        } catch {
            statusText = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
