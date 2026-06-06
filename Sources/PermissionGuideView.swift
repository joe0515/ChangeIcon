import SwiftUI

/// Modal overlay shown on first launch (or when permissions are missing).
///
/// Lists all system permissions with status indicators.
/// Auto-dismisses once all core permissions are granted
/// (via `shouldShowGuide` in ChangeIconApp).
struct PermissionGuideView: View {
    @ObservedObject var permissions: PermissionManager

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
                    ForEach(AppPermission.allCases) { permission in
                        let granted = permissions.isGranted(permission)
                        PermissionRow(
                            permission: permission,
                            isGranted: granted
                        ) {
                            permissions.openSettings(for: permission)
                            permissions.startPolling()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)

                        if permission != AppPermission.allCases.last {
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
                    Label("所有权限已开启", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.body)
                        .fontWeight(.medium)
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
        .onAppear {
            permissions.checkAll()
            permissions.startPolling()
        }
        .onDisappear { permissions.stopPolling() }
        .onChange(of: permissions.allGranted) { _, granted in
            if granted {
                permissions.stopPolling()
                permissions.userDismissed = true
            }
        }
    }
}

// MARK: - Permission Row

private struct PermissionRow: View {
    let permission: AppPermission
    let isGranted: Bool
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

            // Action / Status button
            if isGranted {
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
