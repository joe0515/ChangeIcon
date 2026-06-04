import AppKit
import Foundation
import ServiceManagement
import OSLog

private let logger = Logger(subsystem: "com.local.ChangeIcon", category: "Permission")

// MARK: - Permission Types

enum AppPermission: String, CaseIterable, Identifiable {
    case loginItem
    case fullDiskAccess
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loginItem:      "开机启动权限"
        case .fullDiskAccess: "全盘访问权限"
        case .accessibility:  "辅助控制权限"
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
        }
    }

    var iconName: String {
        switch self {
        case .loginItem:      "poweron"
        case .fullDiskAccess: "internaldrive"
        case .accessibility:  "accessibility"
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
        }
    }
}

// MARK: - Permission Manager

/// Manages detection and status of three system permissions:
/// - Login item: ensures the app auto-starts on login
/// - Full disk access: needed to modify icons on system-level apps
/// - Accessibility: ensures stable background monitoring of theme changes
///
/// On init, auto-checks all permissions and attempts to register the login item.
/// Supports polling for permission changes while the user is in System Settings.
@MainActor
final class PermissionManager: ObservableObject {
    @Published var loginItemGranted = false
    @Published var fullDiskAccessGranted = false
    @Published var accessibilityGranted = false

    private var pollTask: Task<Void, Never>?

    /// Whether the user has chosen to skip the permission guide this session.
    @Published var userDismissed = false

    var allGranted: Bool {
        loginItemGranted && fullDiskAccessGranted && accessibilityGranted
    }

    var missingPermissions: [AppPermission] {
        var missing: [AppPermission] = []
        if !loginItemGranted { missing.append(.loginItem) }
        if !fullDiskAccessGranted { missing.append(.fullDiskAccess) }
        if !accessibilityGranted { missing.append(.accessibility) }
        return missing
    }

    /// Run all permission checks. Safe to call at any time;
    /// publishes updates via the @Published properties.
    func checkAll() {
        let prev = allGranted
        checkLoginItem()
        checkFullDiskAccess()
        checkAccessibility()

        if !prev, allGranted {
            logger.info("All permissions now granted — auto-dismissing guide")
        }
    }

    // MARK: - Polling

    /// Begin polling for permission changes every second.
    /// Stops automatically when all permissions are granted.
    func startPolling() {
        stopPolling()
        pollTask = Task {
            while !Task.isCancelled, !self.allGranted {
                checkAll()
                if allGranted { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            logger.info("Polling stopped — allGranted=\(self.allGranted)")
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Open Settings

    func openSettings(for permission: AppPermission) {
        guard let url = URL(string: permission.settingsURLString) else { return }
        logger.info("Opening settings for \(permission.rawValue): \(permission.settingsURLString)")
        NSWorkspace.shared.open(url)
    }

    func openAllMissingSettings() {
        let missing = missingPermissions
        logger.info("Opening all missing permission settings (\(missing.count))")
        for (i, p) in missing.enumerated() {
            if i > 0 {
                // Brief delay to avoid overwhelming the system
                Thread.sleep(forTimeInterval: 0.3)
            }
            openSettings(for: p)
        }
    }

    // MARK: - Private Checks

    /// Attempt to auto-register as a login item via SMAppService.
    /// Falls back to status check if registration fails.
    private var loginItemRegisterAttempted = false

    private func checkLoginItem() {
        if !loginItemRegisterAttempted {
            loginItemRegisterAttempted = true
            do {
                try SMAppService.mainApp.register()
                loginItemGranted = true
                logger.info("Login item auto-registered successfully")
                return
            } catch {
                logger.warning("Login item registration failed: \(error.localizedDescription)")
            }
        }
        loginItemGranted = SMAppService.mainApp.status == .enabled
    }

    /// Full disk access is required to set icons on files in /Applications.
    /// We test this by attempting to open a system-level file for reading.
    private func checkFullDiskAccess() {
        // This file is readable iff the app has Full Disk Access permission
        let path = "/Library/Preferences/com.apple.loginwindow.plist"
        if let file = FileHandle(forReadingAtPath: path) {
            try? file.close()
            fullDiskAccessGranted = true
        } else {
            fullDiskAccessGranted = false
        }
    }

    /// Accessibility permission ensures the app can maintain its event loop
    /// and Darwin notification delivery when backgrounded.
    private func checkAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }
}
