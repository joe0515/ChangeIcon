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
            "开启后软件可以修改更多系统级应用的图标，提升兼容性"
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
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement"
        }
    }
}

// MARK: - Permission Manager

/// Manages detection and status of four system permissions:
/// - Login item: ensures the app auto-starts on login
/// - Full disk access: needed to modify icons on system-level apps
/// - Accessibility: ensures stable background monitoring of theme changes
/// - App Management: allows deeper app icon modification via Apple Events
///
/// **Checks all permissions on init** so the guide reflects reality immediately,
/// eliminating the brief flash of stale state on first render after a restart.
@MainActor
final class PermissionManager: ObservableObject {
    @Published var loginItemGranted = false
    @Published var fullDiskAccessGranted = false
    @Published var accessibilityGranted = false
    @Published var appManagementGranted = false

    private var pollTask: Task<Void, Never>?

    /// Whether the user has chosen to skip the permission guide this session.
    @Published var userDismissed = false

    /// Core permissions: the guide won't auto-dismiss until these are all granted.
    var allGranted: Bool {
        fullDiskAccessGranted && accessibilityGranted
    }

    /// All permissions (including recommendations like appManagement).
    var allChecked: Bool {
        allGranted && appManagementGranted
    }

    var missingPermissions: [AppPermission] {
        var missing: [AppPermission] = []
        if !loginItemGranted    { missing.append(.loginItem) }
        if !fullDiskAccessGranted { missing.append(.fullDiskAccess) }
        if !accessibilityGranted  { missing.append(.accessibility) }
        if !appManagementGranted  { missing.append(.appManagement) }
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

    /// Check immediately on init so @Published values reflect reality
    /// before the first SwiftUI render cycle.
    init() {
        checkAll()
        logger.info("PermissionManager initialized — allGranted=\(self.allGranted)")
    }

    // MARK: - Check All

    /// Run all permission checks. Safe to call at any time;
    /// publishes updates via the @Published properties.
    func checkAll() {
        let prev = allGranted
        checkLoginItem()
        checkFullDiskAccess()
        checkAccessibility()
        checkAppManagement()

        if !prev, allGranted {
            logger.info("All permissions now granted — auto-dismissing guide")
        }
    }

    // MARK: - Polling

    /// Begin polling for permission changes every second.
    /// Stops automatically when core permissions are all granted.
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
                Thread.sleep(forTimeInterval: 0.3)
            }
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
            logger.info("loginItem: \(self.loginItemGranted) → \(newValue)")
        }
        loginItemGranted = newValue
    }

    /// Full disk access is required to set icons on files in /Applications.
    /// We test this by attempting to open a system-level file for reading.
    private func checkFullDiskAccess() {
        let path = "/Library/Preferences/com.apple.loginwindow.plist"
        let newValue: Bool
        if let file = FileHandle(forReadingAtPath: path) {
            try? file.close()
            newValue = true
        } else {
            newValue = false
        }
        if fullDiskAccessGranted != newValue {
            logger.info("fullDiskAccess: \(self.fullDiskAccessGranted) → \(newValue)")
        }
        fullDiskAccessGranted = newValue
    }

    /// Accessibility permission ensures the app can maintain its event loop
    /// and Darwin notification delivery when backgrounded.
    private func checkAccessibility() {
        let newValue = AXIsProcessTrusted()
        if accessibilityGranted != newValue {
            logger.info("accessibility: \(self.accessibilityGranted) → \(newValue)")
        }
        accessibilityGranted = newValue
    }

    /// App Management permission allows Apple Event access to other applications.
    /// Tested by attempting a minimal AppleScript operation against Finder.
    /// This is a recommendation (non-blocking) — not included in `allGranted`.
    private func checkAppManagement() {
        let script = "tell application \"Finder\" to get name of startup disk"
        guard let appleScript = NSAppleScript(source: script) else {
            appManagementGranted = false
            return
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        let newValue = error == nil
        if appManagementGranted != newValue {
            logger.info("appManagement: \(self.appManagementGranted) → \(newValue)")
        }
        appManagementGranted = newValue
    }
}
