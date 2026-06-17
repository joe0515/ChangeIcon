import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: IconSchemeStore
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var sudoersManager: SudoersManager

    @State private var statusText = ""
    @State private var isConfiguringSudoers = false
    @State private var isUninstallingSudoers = false
    @State private var showUninstallConfirm = false

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

            // ── Sudoers Configuration ──
            VStack(alignment: .leading, spacing: 8) {
                Text("管理员授权状态")
                    .font(.body)

                HStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled")
                        .frame(width: 18)
                        .foregroundStyle(sudoersManager.isConfigured ? .green : .secondary)

                    if sudoersManager.isConfigured {
                        Text("已配置（免密码切换）")
                            .font(.callout)
                        Spacer()
                        Label("已开启", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text("未配置")
                            .font(.callout)
                        Spacer()
                        Label("未开启", systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if sudoersManager.isConfigured {
                    Text("已配置 sudoers 规则，切换图标时无需输入管理员密码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 28)
                } else {
                    Text("配置后可免密码切换图标。需要一次管理员授权写入 sudoers 规则。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 28)
                }

                HStack(spacing: 12) {
                    if !sudoersManager.isConfigured {
                        Button {
                            Task {
                                isConfiguringSudoers = true
                                defer { isConfiguringSudoers = false }
                                do {
                                    try await sudoersManager.install()
                                } catch let error as SudoersError {
                                    if case .adminCancelled = error {
                                        // User cancelled — not an error
                                    }
                                } catch {
                                    // Error details already logged by SudoersManager
                                }
                            }
                        } label: {
                            if isConfiguringSudoers {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 16, height: 16)
                            }
                            Text("配置免密码授权")
                        }
                        .disabled(isConfiguringSudoers)
                    } else {
                        Button(role: .destructive) {
                            showUninstallConfirm = true
                        } label: {
                            if isUninstallingSudoers {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 16, height: 16)
                            }
                            Text("移除授权")
                        }
                        .disabled(isUninstallingSudoers)
                        .confirmationDialog(
                            "确认移除管理员授权",
                            isPresented: $showUninstallConfirm
                        ) {
                            Button("移除授权", role: .destructive) {
                                Task {
                                    isUninstallingSudoers = true
                                    defer { isUninstallingSudoers = false }
                                    do {
                                        try await sudoersManager.uninstall()
                                    } catch {
                                        // Error details already logged
                                    }
                                }
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("移除后，每次切换图标都需要输入管理员密码。")
                        }
                    }

                    Spacer()

                    Button {
                        Task { await sudoersManager.checkConfiguration() }
                    } label: {
                        Text("重新检测")
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
        .task {
            await sudoersManager.checkConfiguration()
        }
    }
}
