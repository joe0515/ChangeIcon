import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.local.ChangeIcon", category: "Dock")

// MARK: - Dock item info

struct DockItemInfo {
    let bundleID: String
    let appPath: String
    let appName: String
    let isRunning: Bool
    let isPinned: Bool
}

// MARK: - Dock Manager

/// Handles the Dock's multi-layer icon cache:
///
/// **Layer 1 — File metadata** (setIcon writes here, Finder/LaunchPad reads)
/// **Layer 2 — Dock persistent entry cache** (com.apple.dock.plist)
/// **Layer 3 — Global iconservices cache** (/private/var/folders/.../com.apple.iconservices)
///
/// The critical insight: when re-adding a Dock persistent entry, macOS reads
/// from Layer 3 (global cache), NOT from Layer 1 (file metadata). Only when
/// the app LAUNCHES does macOS flush all caches from file metadata.
///
/// Fix: clear Layer 3 BEFORE refreshing Dock entries, forcing a re-read from
/// Layer 1. Also, the restart flow must be: quit → refresh Dock → launch
/// (not quit → launch → refresh, because launch immediately loads stale cache).
@MainActor
final class DockManager: ObservableObject {
    @Published var needsRestartAlert = false
    @Published var restartAlertTitle = ""
    @Published var restartAlertMessage = ""
    @Published var restartApps: [(appPath: String, appName: String, bundleID: String)] = []

    private let fm = FileManager.default

    // MARK: - Detection

    func bundleID(for appPath: String) -> String? {
        Bundle(path: appPath)?.bundleIdentifier
    }

    func isAppRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    func isAppPinnedToDock(bundleID: String) -> Bool {
        guard let dockPrefs = UserDefaults(suiteName: "com.apple.dock"),
              let apps = dockPrefs.array(forKey: "persistent-apps") as? [[String: Any]] else {
            return false
        }
        for app in apps {
            guard let td = app["tile-data"] as? [String: Any],
                  let fd = td["file-data"] as? [String: Any],
                  let urlStr = fd["_CFURLString"] as? String,
                  let url = URL(string: urlStr),
                  let b = Bundle(url: url) else { continue }
            if b.bundleIdentifier == bundleID { return true }
        }
        return false
    }

    func analyze(appPaths: [String]) -> [DockItemInfo] {
        appPaths.compactMap { path in
            guard let bid = bundleID(for: path) else { return nil }
            return DockItemInfo(
                bundleID: bid,
                appPath: path,
                appName: fm.displayName(atPath: path),
                isRunning: isAppRunning(bundleID: bid),
                isPinned: isAppPinnedToDock(bundleID: bid)
            )
        }
    }

    // MARK: - Global icon cache

    /// Clear the system-wide iconservices cache.
    /// This is the key to fixing the "always-inverted" icon problem.
    /// The cache at /private/var/folders/.../com.apple.iconservices stores
    /// a copy of every app's icon that the Dock reads from. Without clearing
    /// it, re-adding a Dock entry will load stale icons.
    func clearGlobalIconCache() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        task.arguments = [
            "/private/var/folders",
            "-name", "com.apple.dock.iconcache",
            "-o", "-name", "com.apple.iconservices",
            "-exec", "rm", "-rf", "{}", ";"
        ]
        try? task.run()
        task.waitUntilExit()
        logger.info("Global icon cache cleared")
    }

    // MARK: - Restart (quit → refresh Dock → launch)

    /// Restart a running app with the correct order:
    /// 1. Terminate the app
    /// 2. Wait for it to fully exit
    /// 3. Refresh Dock persistent entries (while app is NOT running)
    /// 4. Wait for Dock cache sync
    /// 5. Launch the app fresh (this forces all caches to read from file metadata)
    func restartApplication(bundleID: String, appPath: String) async -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else { return false }

        logger.info("Restarting \(bundleID)")

        app.terminate()

        for _ in 0..<50 {
            if !isAppRunning(bundleID: bundleID) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !isAppRunning(bundleID: bundleID) else {
            logger.warning("App \(bundleID) did not terminate in time")
            return false
        }

        clearGlobalIconCache()
        try? await Task.sleep(nanoseconds: 300_000_000)

        if isAppPinnedToDock(bundleID: bundleID) {
            refreshDockPersistentItem(appPath: appPath)
        }

        try? await Task.sleep(nanoseconds: 800_000_000)

        let success = NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
        logger.info("Relaunched \(appPath): \(success)")
        return success
    }

    // MARK: - Dock persistent item refresh

    /// Refresh a Dock-pinned item by removing it, clearing caches, and re-adding.
    /// This must be called while the app is NOT running to work correctly.
    func refreshDockPersistentItem(appPath: String) {
        let appName = fm.displayName(atPath: appPath)
        logger.info("Refreshing Dock persistent item for \(appName)")

        clearGlobalIconCache()
        Thread.sleep(forTimeInterval: 0.6)

        // Remove from Dock via defaults (locale-independent)
        if let dockPrefs = UserDefaults(suiteName: "com.apple.dock"),
           var apps = dockPrefs.array(forKey: "persistent-apps") as? [[String: Any]] {
            apps.removeAll { entry in
                guard let td = entry["tile-data"] as? [String: Any],
                      let fd = td["file-data"] as? [String: Any],
                      let urlStr = fd["_CFURLString"] as? String else { return false }
                return urlStr.contains(appPath)
            }
            dockPrefs.set(apps, forKey: "persistent-apps")
        }

        // Add back via defaults
        if let dockPrefs = UserDefaults(suiteName: "com.apple.dock"),
           var apps = dockPrefs.array(forKey: "persistent-apps") as? [[String: Any]] {
            let newEntry: [String: Any] = [
                "tile-data": [
                    "file-data": [
                        "_CFURLString": "file://\(appPath)",
                        "_CFURLStringType": 15
                    ]
                ],
                "tile-type": "file-tile"
            ]
            apps.append(newEntry)
            dockPrefs.set(apps, forKey: "persistent-apps")
        }

        let dk = Process()
        dk.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        dk.arguments = ["Dock"]
        try? dk.run()
        dk.waitUntilExit()

        NSWorkspace.shared.noteFileSystemChanged(appPath)
        logger.info("Dock persistent item refreshed for \(appName)")
    }

    // MARK: - Batch operations

    func prepareRestartAlert(runningApps: [(appPath: String, appName: String, bundleID: String)]) {
        restartApps = runningApps
        let names = runningApps.map(\.appName).joined(separator: "、")
        if runningApps.count == 1 {
            restartAlertTitle = "需要重启才能更新Dock图标"
            restartAlertMessage = "\(names) 正在运行中，Dock图标需要重启应用后才能更新。\n\n重启流程：退出 → 刷新Dock缓存 → 重新启动"
        } else {
            restartAlertTitle = "\(runningApps.count) 个应用需要重启"
            restartAlertMessage = "\(names) 正在运行中，Dock图标需要重启应用后才能更新。"
        }
        needsRestartAlert = true
    }

    func restartAllQueuedApps() async {
        for app in restartApps {
            _ = await restartApplication(bundleID: app.bundleID, appPath: app.appPath)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        restartApps.removeAll()
        needsRestartAlert = false
    }
}
