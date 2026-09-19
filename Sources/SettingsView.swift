import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: IconSchemeStore
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var sudoersManager: SudoersManager
    @EnvironmentObject private var backup: BackupManager

    @State private var statusText = ""
    @State private var isConfiguringSudoers = false
    @State private var isUninstallingSudoers = false
    @State private var showUninstallConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                backupSection
                loginItemSection
                permissionSection
                sudoersSection
            }
            .padding(24)
        }
        .frame(width: 480)
        .task { await sudoersManager.checkConfiguration() }
    }

    // MARK: - Backup Section

    /// 备份文件自定义 UTI（在 Info.plist 中声明），本质是 zip 归档。
    private var backupContentType: UTType {
        UTType(exportedAs: "com.local.ChangeIcon.backup", conformingTo: .zip)
    }

    private var defaultBackupName: String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        return "ChangeIcon备份-\(df.string(from: Date())).changeiconbackup"
    }

    private var isBackupError: Bool {
        backup.summary.contains("失败")
    }

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(icon: "externaldrive.badge.timemachine", title: "备份与恢复", tint: .blue)

            Text("导出所有图标方案及对应的深浅色图标文件，可在更换设备或重装后一键恢复。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("当前方案")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.schemes.count)")
                    .font(.callout)
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                Button {
                    exportBackup()
                } label: {
                    Label("导出备份", systemImage: "square.and.arrow.up")
                }
                .glassButtonStyle(primary: true)
                .disabled(backup.isWorking)

                Button {
                    importBackup()
                } label: {
                    Label("导入备份", systemImage: "square.and.arrow.down")
                }
                .glassButtonStyle(primary: false)
                .disabled(backup.isWorking)

                Spacer()
            }

            if backup.isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在处理备份…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !backup.summary.isEmpty {
                Label(
                    backup.summary,
                    systemImage: isBackupError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(isBackupError ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    // MARK: - Login Item Section

    private var loginItemSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "power", title: "启动", tint: .green)

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

            Text("自动切换需要 ChangeIcon 保持运行。登录时启动可以让浅色和深色模式切换更及时。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !statusText.isEmpty {
                Label(statusText, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    // MARK: - Permission Section

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "lock.shield", title: "权限状态", tint: .orange)

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

                if permission == .appManagement {
                    Text("开启路径：系统设置 → 隐私与安全性 → App 管理 → 添加 ChangeIcon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 28)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if permission != .appManagement {
                    Divider()
                }
            }

            HStack {
                Spacer()
                Button("重新检测") {
                    permissions.checkAll()
                }
                .glassButtonStyle(primary: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    // MARK: - Sudoers Section

    private var sudoersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "shield.lefthalf.filled", title: "管理员授权", tint: .purple)

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

            Text(sudoersManager.isConfigured
                 ? "已配置 sudoers 规则，切换图标时无需输入管理员密码。"
                 : "配置后可免密码切换图标。需要一次管理员授权写入 sudoers 规则。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
                .fixedSize(horizontal: false, vertical: true)

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
                                    // 用户取消——非错误
                                }
                            } catch {
                                // 错误已由 SudoersManager 记录
                            }
                        }
                    } label: {
                        if isConfiguringSudoers {
                            ProgressView().controlSize(.small)
                        }
                        Text("配置免密码授权")
                    }
                    .glassButtonStyle(primary: true)
                    .disabled(isConfiguringSudoers)
                } else {
                    Button(role: .destructive) {
                        showUninstallConfirm = true
                    } label: {
                        if isUninstallingSudoers {
                            ProgressView().controlSize(.small)
                        }
                        Text("移除授权")
                    }
                    .glassButtonStyle(primary: false)
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
                                    // 错误已记录
                                }
                            }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("移除后，每次切换图标都需要输入管理员密码。")
                    }
                }

                Spacer()

                Button("重新检测") {
                    Task { await sudoersManager.checkConfiguration() }
                }
                .glassButtonStyle(primary: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    // MARK: - Section Header

    private func sectionHeader(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(title)
                .font(.headline)
        }
    }

    // MARK: - Actions

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.title = "导出用户数据备份"
        panel.nameFieldStringValue = defaultBackupName
        panel.allowedContentTypes = [backupContentType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await backup.exportBackup(schemes: store.schemes, to: url) }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.title = "导入用户数据备份"
        panel.allowedContentTypes = [backupContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let restored = await backup.importBackup(from: url) {
                store.applyBackup(restored)
            }
        }
    }
}
