import SwiftUI

/// Modal overlay shown on first launch (or when permissions are missing).
///
/// Lists all missing system permissions with descriptions and action buttons.
/// Auto-dismisses once all permissions are granted, or when the user taps "稍后再说".
struct PermissionGuideView: View {
    @Environment(\.dismiss) private var dismiss
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
                    ForEach(permissions.missingPermissions) { permission in
                        PermissionRow(permission: permission) {
                            permissions.openSettings(for: permission)
                            permissions.startPolling()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)

                        if permission != permissions.missingPermissions.last {
                            Divider()
                                .padding(.horizontal, 20)
                        }
                    }
                }
            }

            Divider()

            // ── Footer ──
            VStack(spacing: 12) {
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

                Button("稍后再说") {
                    permissions.stopPolling()
                    permissions.userDismissed = true
                }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 20)
        }
        .frame(width: 520, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { permissions.stopPolling() }
        .onDisappear { permissions.stopPolling() }
        .onChange(of: permissions.allGranted) { _, granted in
            if granted {
                permissions.stopPolling()
            }
        }
    }
}

// MARK: - Permission Row

private struct PermissionRow: View {
    let permission: AppPermission
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            Image(systemName: permission.iconName)
                .font(.system(size: 28))
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
                .background(Color.blue.opacity(0.1))
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

            // Action button
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
