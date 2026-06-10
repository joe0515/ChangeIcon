import AppKit
import Foundation
import ServiceManagement
import OSLog

private let permLog = Logger(subsystem: "com.local.ChangeIcon", category: "Permission")

// MARK: - Permission Types

enum AppPermission: String, CaseIterable, Identifiable {
    case loginItem
    case fullDiskAccess
    case accessibility
    case appManagement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loginItem:      "开机启动权限"
        case .fullDiskAccess: "全盘访问权限"
        case .accessibility:  "辅助控制权限"
        case .appManagement:  "应用管理权限"
        }
    }

    var description: String {
        switch self {
        case .loginItem:
            "开启后软件会在开机时自动运行，保证深浅色图标自动切换功能正常工作"
        case .fullDiskAccess:
            "开启后软件才能修改系统级应用的图标，保证自动切换功能正常生效"
        case .accessibility:
            "开启后软件能稳定监听系统外观变化，保证深浅色图标切换及时生效"
        case .appManagement:
            "macOS 限制无法自动检测此权限状态。请在隐私与安全性 → App 管理中手动开启，开启后确保可正常使用即可"
        }
    }

    var iconName: String {
        switch self {
        case .loginItem:      "poweron"
        case .fullDiskAccess: "internaldrive"
        case .accessibility:  "accessibility"
        case .appManagement:  "app.badge.checkmark"
        }
    }

    var settingsURLString: String {
        switch self {
        case .loginItem:
            if #available(macOS 13.0, *) {
                return "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
            } else {
                return "x-apple.systempreferences:com.apple.preference.usersandgroups?LoginItems"
            }
        case .fullDiskAccess:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .appManagement:
            return "x-apple.systempreferences:com.apple.preference.security"
        }
    }
}

// MARK: - Permission Manager

/// Manages detection and status of four system permissions.
/// App Management cannot be reliably detected via public API (TCC.db
/// requires FDA and uses ad-hoc signing paths; Apple Events APIs check
/// Automation, not App Management).  It is presented as a manual step.
@MainActor
final class PermissionManager: ObservableObject {
    @Published var loginItemGranted = false
    @Published var fullDiskAccessGranted = false
    @Published var accessibilityGranted = false
    @Published var appManagementGranted = false          // always false — manual step
    @Published var appManagementUndetermined = true       // always true — cannot detect

    private var pollTask: Task<Void, Never>?

    @Published var userDismissed = false

    /// Core permissions: the guide won't auto-dismiss until these are all granted.
    var allGranted: Bool {
        fullDiskAccessGranted && accessibilityGranted
    }

    /// All permissions including App Management (always satisfied by manual step).
    var allChecked: Bool {
        allGranted
    }

    /// Missing permissions — App Management is never included because
    /// it cannot be auto-detected and is a manual-only step.
    var missingPermissions: [AppPermission] {
        var missing: [AppPermission] = []
        if !loginItemGranted    { missing.append(.loginItem) }
        if !fullDiskAccessGranted { missing.append(.fullDiskAccess) }
        if !accessibilityGranted  { missing.append(.accessibility) }
        return missing
    }

    func isGranted(_ permission: AppPermission) -> Bool {
        switch permission {
        case .loginItem:      return loginItemGranted
        case .fullDiskAccess: return fullDiskAccessGranted
        case .accessibility:  return accessibilityGranted
        case .appManagement:  return appManagementGranted
        }
    }

    init() {
        checkAll()
        permLog.info("PermissionManager initialized — allGranted=\(self.allGranted)")
    }

    // MARK: - Check All

    func checkAll() {
        let prev = allGranted
        checkLoginItem()
        checkFullDiskAccess()
        checkAccessibility()

        if !prev, allGranted {
            permLog.info("All permissions now granted — auto-dismissing guide")
        }
    }

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        pollTask = Task {
            while !Task.isCancelled, !self.allGranted {
                checkAll()
                if allGranted { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            permLog.info("Polling stopped — allGranted=\(self.allGranted)")
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Open Settings

    func openSettings(for permission: AppPermission) {
        guard let url = URL(string: permission.settingsURLString) else { return }
        permLog.info("Opening settings for \(permission.rawValue): \(permission.settingsURLString)")
        NSWorkspace.shared.open(url)
    }

    func openAllMissingSettings() {
        let missing = missingPermissions
        permLog.info("Opening all missing permission settings (\(missing.count))")
        for (i, p) in missing.enumerated() {
            if i > 0 { Thread.sleep(forTimeInterval: 0.3) }
            openSettings(for: p)
        }
    }

    // MARK: - Private Checks

    private var loginItemRegisterAttempted = false

    private func checkLoginItem() {
        if !loginItemRegisterAttempted {
            loginItemRegisterAttempted = true
            try? SMAppService.mainApp.register()
        }
        let newValue = SMAppService.mainApp.status == .enabled
        if loginItemGranted != newValue {
            permLog.info("loginItem: \(self.loginItemGranted) → \(newValue)")
        }
        loginItemGranted = newValue
    }

    private func checkFullDiskAccess() {
        let home = NSHomeDirectory()
        let path = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        let newValue: Bool
        if let file = FileHandle(forReadingAtPath: path) {
            try? file.close()
            newValue = true
        } else {
            newValue = false
        }
        if fullDiskAccessGranted != newValue {
            permLog.info("fullDiskAccess: \(self.fullDiskAccessGranted) → \(newValue)")
        }
        fullDiskAccessGranted = newValue
    }

    private func checkAccessibility() {
        let newValue = AXIsProcessTrusted()
        if accessibilityGranted != newValue {
            permLog.info("accessibility: \(self.accessibilityGranted) → \(newValue)")
        }
        accessibilityGranted = newValue
    }
}
