import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: IconSchemeStore
    @EnvironmentObject private var permissions: PermissionManager

    @State private var statusText = ""

    var body: some View {
        Form {
            // ── Login Item ──
            Toggle("登录时启动", isOn: Binding(
                get: { permissions.loginItemGranted },
                set: { enabled in
                    if enabled {
                        do {
                            try SMAppService.mainApp.register()
                            permissions.checkAll()
                            statusText = "已设置为登录时启动。"
                        } catch {
                            statusText = error.localizedDescription
                            permissions.checkAll()
                        }
                    } else {
                        do {
                            try SMAppService.mainApp.unregister()
                            permissions.checkAll()
                            statusText = "已取消登录时启动。"
                        } catch {
                            statusText = error.localizedDescription
                            permissions.checkAll()
                        }
                    }
                }
            ))

            if !statusText.isEmpty {
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Text("自动切换需要 ChangeIcon 保持运行。登录时启动可以让浅色和深色模式切换更及时。")
                .foregroundStyle(.secondary)
                .font(.callout)

            Divider()

            // ── Permissions (re-check button) ──
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("权限状态")
                            .font(.body)
                        let missing = permissions.missingPermissions.map(\.title)
                        if missing.isEmpty {
                            Text("所有权限已开启")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text("未开启: \(missing.joined(separator: "、"))")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Spacer()

                    Button("重新检测") {
                        permissions.checkAll()
                    }
                }
            }

            Divider()

            LabeledContent("已保存方案") {
                Text("\(store.schemes.count)")
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
