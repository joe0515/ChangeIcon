import SwiftUI

/// Modal overlay shown on first launch (or when permissions are missing).
///
/// Lists all system permissions with status indicators, plus the
/// optional sudoers admin authorization for zero-password icon switching.
/// Auto-dismisses once all core permissions are granted.
struct PermissionGuideView: View {
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var sudoersManager: SudoersManager

    @State private var isConfiguringSudoers = false
    @State private var sudoersErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──
            VStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.system(size: 52))
                    .foregroundStyle(.blue)
                    .symbolRenderingMode(.hierarchical)

                Text("需要开启必要权限")
                    .font(.title)
                    .fontWeight(.bold)

                Text("ChangeIcon 需要以下权限才能正常工作。\n请点击「去开启」跳转到系统设置。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(.top, 36)
            .padding(.bottom, 24)

            Divider()

            // ── Permission List ──
            ScrollView {
                VStack(spacing: 0) {
                    // Core permissions shown before admin authorization
                    ForEach(AppPermission.allCases.filter { $0 != .accessibility && $0 != .appManagement }) { permission in
                        let granted = permissions.isGranted(permission)
                        PermissionRow(
                            permission: permission,
                            isGranted: granted,
                            isManualOnly: false
                        ) {
                            permissions.openSettings(for: permission)
                            permissions.startPolling()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)

                        Divider()
                            .padding(.horizontal, 20)
                    }

                    // ── Sudoers Admin Authorization (placed above accessibility) ──
                    sudoersAdminRow
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)

                    Divider()
                        .padding(.horizontal, 20)

                    // Accessibility + App Management (shown after admin auth)
                    ForEach(AppPermission.allCases.filter { $0 == .accessibility || $0 == .appManagement }) { permission in
                        let granted = permissions.isGranted(permission)
                        let isManual = permission == .appManagement
                        PermissionRow(
                            permission: permission,
                            isGranted: granted,
                            isManualOnly: isManual
                        ) {
                            permissions.openSettings(for: permission)
                            permissions.startPolling()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)

                        if permission != .appManagement {
                            Divider()
                                .padding(.horizontal, 20)
                        }
                    }
                }
            }

            Divider()

            // ── Footer ──
            VStack(spacing: 12) {
                if permissions.missingPermissions.isEmpty {
                    VStack(spacing: 6) {
                        Label("所有权限已开启", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.body)
                            .fontWeight(.medium)
                        if !sudoersManager.isConfigured {
                            Text("管理员免密码授权可在上方配置，或稍后在软件设置中授权。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        permissions.openAllMissingSettings()
                        permissions.startPolling()
                    } label: {
                        Label("全部开启", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                            .frame(height: 20)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 20)
                }

                Button("稍后再说") {
                    permissions.stopPolling()
                    permissions.userDismissed = true
                }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 20)
        }
        .frame(width: 520)
        .frame(minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            permissions.checkAll()
            permissions.startPolling()
            await sudoersManager.checkConfiguration()
        }
        .onDisappear { permissions.stopPolling() }
        .alert("管理员授权失败", isPresented: Binding(
            get: { sudoersErrorMessage != nil },
            set: { if !$0 { sudoersErrorMessage = nil } }
        )) {
            Button("好的") { sudoersErrorMessage = nil }
        } message: {
            Text(sudoersErrorMessage ?? "")
        }
    }

    // MARK: - Sudoers Admin Row

    private var sudoersAdminRow: some View {
        HStack(spacing: 16) {
            Image(systemName: sudoersManager.isConfigured ? "shield.checkered" : "shield.lefthalf.filled")
                .font(.system(size: 28))
                .foregroundStyle(sudoersManager.isConfigured ? .green : .blue)
                .frame(width: 44, height: 44)
                .background((sudoersManager.isConfigured ? Color.green : Color.blue).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("管理员免密码授权")
                    .font(.body)
                    .fontWeight(.semibold)
                Text(sudoersManager.isConfigured
                    ? "已配置，切换图标无需输入管理员密码。"
                    : "一次配置即可永久免密码切换图标。若跳过，后续可在软件设置中重新授权。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if sudoersManager.isConfigured {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                    Text("已开启")
                        .fontWeight(.medium)
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            } else {
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
                            sudoersErrorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isConfiguringSudoers {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        Text("去开启")
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isConfiguringSudoers)
            }
        }
    }
}

// MARK: - Permission Row

private struct PermissionRow: View {
    let permission: AppPermission
    let isGranted: Bool
    let isManualOnly: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            Image(systemName: permission.iconName)
                .font(.system(size: 28))
                .foregroundStyle(isGranted ? .green : .blue)
                .frame(width: 44, height: 44)
                .background((isGranted ? Color.green : Color.blue).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            // Text
            VStack(alignment: .leading, spacing: 4) {
                Text(permission.title)
                    .font(.body)
                    .fontWeight(.semibold)
                Text(permission.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // Action / Status
            if isManualOnly {
                Button(action: action) {
                    Text("去开启")
                        .fontWeight(.medium)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if isGranted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                    Text("已开启")
                        .fontWeight(.medium)
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            } else {
                Button(action: action) {
                    Text("去开启")
                        .fontWeight(.medium)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
}
