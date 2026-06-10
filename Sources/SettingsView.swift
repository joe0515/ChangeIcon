import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: IconSchemeStore
    @EnvironmentObject private var permissions: PermissionManager

    @State private var statusText = ""

    var body: some View {
        VStack(spacing: 16) {
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

            // ── Permissions ──
            VStack(alignment: .leading, spacing: 8) {
                Text("权限状态")
                    .font(.body)

                ForEach(AppPermission.allCases) { permission in
                    HStack(spacing: 10) {
                        Image(systemName: permission.iconName)
                            .frame(width: 18)
                            .foregroundStyle(permissions.isGranted(permission) ? .green : .secondary)
                        Text(permission.title)
                            .font(.callout)
                        Spacer()
                        if permission == .appManagement {
                            Label("请手动确认", systemImage: "hand.point.up.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        } else if permissions.isGranted(permission) {
                            Label("已开启", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("未开启", systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    // Path hint for App Management
                    if permission == .appManagement {
                        Text("开启路径：系统设置 → 隐私与安全性 → App 管理 → 添加 ChangeIcon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 28)
                    }

                    Divider()
                }

                HStack {
                    Spacer()
                    Button("重新检测") {
                        permissions.checkAll()
                    }
                }
            }

            Divider()

            HStack {
                Text("已保存方案")
                Spacer()
                Text("\(store.schemes.count)")
            }
        }
        .frame(width: 440)
        .padding(24)
    }
}
