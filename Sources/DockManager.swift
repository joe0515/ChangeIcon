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

    /// Clear ALL known icon caches that Dock reads from.
    /// The Dock reads icons from multiple cache layers; missing any one
    /// of them causes the "one-beat-behind" inverted icon problem.
    func clearGlobalIconCache() {
        let cachePaths: [String] = [
            // Layer 1: Per-user icon cache store (primary source for Dock)
            NSHomeDirectory() + "/Library/Caches/com.apple.iconservices.store",
            // Layer 2: Dock-specific container caches
            NSHomeDirectory() + "/Library/Containers/com.apple.dock/Data/Library/Caches",
            // Layer 3: System-wide per-user caches (multiple UUID dirs)
            "/private/var/folders",
        ]

        for path in cachePaths {
            if path.contains("/private/var/folders") {
                // For system caches: find and remove specific cache dirs
                let findTask = Process()
                findTask.executableURL = URL(fileURLWithPath: "/usr/bin/find")
                findTask.arguments = [
                    path,
                    "-maxdepth", "4",
                    "(", "-name", "com.apple.iconservices", "-o", "-name", "com.apple.dock.iconcache", ")",
                    "-exec", "rm", "-rf", "{}", ";"
                ]
                try? findTask.run()
                findTask.waitUntilExit()
            } else {
                // For user paths: directly delete
                if fm.fileExists(atPath: path) {
                    try? fm.removeItem(atPath: path)
                }
            }
        }

        logger.info("All icon caches cleared")
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
        if isAppRunning(bundleID: bundleID) {
            logger.warning("App \(bundleID) did not terminate gracefully, force terminating")
            NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bundleID })?
                .forceTerminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard !isAppRunning(bundleID: bundleID) else {
            logger.error("App \(bundleID) did not terminate even after force termination")
            return false
        }

        clearGlobalIconCache()
        try? await Task.sleep(nanoseconds: 300_000_000)

        if isAppPinnedToDock(bundleID: bundleID) {
            await refreshDockPersistentItem(appPath: appPath)
        }

        try? await Task.sleep(nanoseconds: 800_000_000)

        let success = NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
        logger.info("Relaunched \(appPath): \(success)")
        return success
    }

    // MARK: - Dock persistent item refresh

    /// Force-refresh a single app's Dock icon by clearing all relevant caches
    /// and rebuilding the Dock persistent entry. Handles the case where Dock
    /// shows a color-inverted / stale icon while Finder/LaunchPad show correctly.
    func forceDockIconRefresh(appPath: String, bundleID: String, restartDock: Bool = true) async {
        let appName = fm.displayName(atPath: appPath)
        let appURL = URL(fileURLWithPath: appPath)
        logger.info("Force-refreshing Dock icon for \(appName)")

        // 1. Touch the app bundle so Dock's fsevents watcher notices
        let attrs: [FileAttributeKey: Any] = [.modificationDate: Date()]
        try? fm.setAttributes(attrs, ofItemAtPath: appPath)

        // 2. Clear ALL icon caches (covers multiple layers)
        clearGlobalIconCache()
        try? await Task.sleep(nanoseconds: 500_000_000)

        // 3. Remove existing Dock entry (capture original index and entry first)
        var originalIndex: Int?
        var originalEntry: [String: Any]?
        let dockSuite = UserDefaults(suiteName: "com.apple.dock")
        if var apps = dockSuite?.array(forKey: "persistent-apps") as? [[String: Any]] {
            if let idx = apps.firstIndex(where: { entry in
                guard let td = entry["tile-data"] as? [String: Any],
                      let fd = td["file-data"] as? [String: Any],
                      let urlStr = fd["_CFURLString"] as? String,
                      let url = URL(string: urlStr) else { return false }
                return url.standardizedFileURL == appURL.standardizedFileURL
            }) {
                originalIndex = idx
                originalEntry = apps[idx]
            }
            apps.removeAll { entry in
                guard let td = entry["tile-data"] as? [String: Any],
                      let fd = td["file-data"] as? [String: Any],
                      let urlStr = fd["_CFURLString"] as? String,
                      let url = URL(string: urlStr) else { return false }
                return url.standardizedFileURL == appURL.standardizedFileURL
            }
            dockSuite?.set(apps, forKey: "persistent-apps")
            dockSuite?.synchronize()
        }

        try? await Task.sleep(nanoseconds: 200_000_000)

        // 4. Re-add Dock entry at original position preserving all fields
        if var apps = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] {
            let newEntry: [String: Any]
            if var entry = originalEntry {
                // Rebuild from original entry — only update the path in file-data
                // to preserve GUID, arrangement, displayas, and other Dock metadata.
                if var td = entry["tile-data"] as? [String: Any],
                   var fd = td["file-data"] as? [String: Any] {
                    fd["_CFURLString"] = "file://\(appPath)"
                    fd["_CFURLStringType"] = 15
                    td["file-data"] = fd
                    entry["tile-data"] = td
                }
                newEntry = entry
            } else {
                // Fallback: original entry not found — build minimal entry
                newEntry = [
                    "tile-data": [
                        "file-data": [
                            "_CFURLString": "file://\(appPath)",
                            "_CFURLStringType": 15
                        ]
                    ],
                    "tile-type": "file-tile"
                ]
            }
            // Insert at original position; fallback to append if index is out of bounds
            if let idx = originalIndex, idx <= apps.count {
                apps.insert(newEntry, at: idx)
            } else {
                apps.append(newEntry)
            }
            UserDefaults(suiteName: "com.apple.dock")?.set(apps, forKey: "persistent-apps")
            UserDefaults(suiteName: "com.apple.dock")?.synchronize()
        }

        // 5. Restart Dock (skipped when caller manages Dock restart centrally)
        if restartDock {
            let dk = Process()
            dk.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            dk.arguments = ["Dock"]
            try? dk.run()
            dk.waitUntilExit()
        }

        // 6. Notify system + touch again after Dock restart
        NSWorkspace.shared.noteFileSystemChanged(appPath)
        try? fm.setAttributes(attrs, ofItemAtPath: appPath)

        logger.info("Dock icon force-refreshed for \(appName)")
    }

    /// Refresh a Dock-pinned item by removing it, clearing caches, and re-adding.
    /// This must be called while the app is NOT running to work correctly.
    func refreshDockPersistentItem(appPath: String) async {
        guard let bundleID = bundleID(for: appPath) else {
            logger.warning("Cannot refresh Dock item: no bundleID for \(appPath)")
            return
        }
        await forceDockIconRefresh(appPath: appPath, bundleID: bundleID)
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
