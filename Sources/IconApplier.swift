import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.local.ChangeIcon", category: "IconApplier")

/// Applies custom icons to applications using `NSWorkspace.shared.setIcon()`.
///
/// ## Architecture
///
/// This is the core rewrite that replaces the old daemon + osascript-admin approach
/// with a simple in-process call to `NSWorkspace.shared.setIcon()`.
///
/// The old approach used:
///   - A privileged helper daemon (`seticon_daemon.swift`) running via launchd
///   - A file-based IPC mechanism polling `/Users/Shared/.ChangeIcon/Commands/`
///   - `osascript` with `with administrator privileges` for every icon change
///
/// The new approach uses:
///   1. Direct `NSWorkspace.shared.setIcon()` in-process (fast, non-destructive)
///   2. Writes to file metadata (com.apple.FinderInfo xattr), NOT the bundle .icns
///   3. Does NOT break code signing — no SIP workaround needed
///   4. Falls back to admin helper only when the app bundle is not user-writable
///
/// ### Why this works without admin for most apps
///
/// Apps installed by dragging from a DMG to `/Applications` are owned by the user.
/// `setIcon()` writes an extended attribute on the bundle — the user owns the file,
/// so the write succeeds. Only system apps (Finder, Safari, etc.) or apps installed
/// by another admin user are unwritable.
@MainActor
final class IconApplier: ObservableObject {
    @Published private(set) var isApplying = false
    @Published var logs: [OperationLog] = []
    @Published var currentProgress: (current: Int, total: Int)?
    @Published var needsPermissionSetup = false
    @Published var permissionGuideMessage = ""

    private let fm = FileManager.default

    // ──────────────────────────────────────────────
    // MARK: - Public API
    // ──────────────────────────────────────────────

    /// Apply icons to schemes that need updating.
    /// - Parameters:
    ///   - force: If true, applies even if `lastAppliedMode` matches.
    func applyIfNeeded(schemes: [IconScheme], appearance: AppearanceMode, force: Bool = false) async {
        let targets = schemes.filter { s in
            guard s.enabled, let _ = s.iconURL(for: appearance) else { return false }
            return force || s.lastAppliedMode != appearance
        }
        logger.info("applyIfNeeded: mode=\(appearance.title) targets=\(targets.count)")
        guard !targets.isEmpty else { return }
        await apply(targets, appearance: appearance)
    }

    /// Apply a specific set of schemes for the given appearance.
    func apply(_ schemes: [IconScheme], appearance: AppearanceMode) async {
        isApplying = true
        currentProgress = (0, schemes.count)
        defer {
            isApplying = false
            currentProgress = nil
        }
        needsPermissionSetup = false
        permissionGuideMessage = ""

        for (i, scheme) in schemes.enumerated() {
            currentProgress = (i + 1, schemes.count)
            guard let iconURL = scheme.iconURL(for: appearance) else { continue }

            do {
                try await applyIconOnce(app: scheme.appURL, icon: iconURL)
                appendLog("已为 \(scheme.appName) 应用\(appearance.title)图标", isError: false)
                NotificationCenter.default.post(
                    name: .iconSchemeApplied, object: nil,
                    userInfo: ["id": scheme.id, "mode": appearance]
                )
            } catch let error as IconError {
                logger.error("apply failed for \(scheme.appName): \(error.errorDescription ?? "")")
                appendLog("\(scheme.appName): \(error.errorDescription ?? "操作失败")", isError: true)

                switch error {
                case .systemApp:
                    needsPermissionSetup = true
                    permissionGuideMessage = "系统应用（如 Finder、Safari）需要关闭 SIP 才能更换图标。\n\n操作指引：重启 Mac → 按住 Cmd+R 进入恢复模式 → 打开终端 → 运行 `csrutil disable` → 重启。"
                case .needsAdmin:
                    needsPermissionSetup = true
                    permissionGuideMessage = "需要管理员授权才能修改该应用图标。\n\n在弹出的密码框中输入密码。如果频繁出现此提示，建议将应用移至 ~/Applications 目录。"
                case .adminCancelled:
                    needsPermissionSetup = true
                    permissionGuideMessage = "管理员授权被取消。如果该应用位于 /Applications 目录，可以将其拖到 ~/Applications 下，ChangeIcon 即可直接修改。"
                default:
                    break
                }
            } catch {
                logger.error("apply failed for \(scheme.appName): \(error.localizedDescription)")
                appendLog("\(scheme.appName): \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Restore an app's original icon by clearing the custom icon.
    func restore(_ scheme: IconScheme) async {
        isApplying = true
        defer { isApplying = false }
        do {
            try await clearIcon(app: scheme.appURL.path)
            appendLog("已恢复 \(scheme.appName) 的原始图标", isError: false)
        } catch {
            appendLog("恢复失败: \(error.localizedDescription)", isError: true)
        }
    }

    /// Force refresh the icon cache in Dock and Finder.
    func refreshIconCache(for appURLs: [URL]) async {
        for u in appURLs {
            NSWorkspace.shared.noteFileSystemChanged(u.path)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/killall"), arguments: ["Dock"])
        appendLog("已刷新图标缓存", isError: false)
    }

    // ──────────────────────────────────────────────
    // MARK: - Core Icon Logic
    // ──────────────────────────────────────────────

    /// Apply a single icon to a single app.
    ///
    /// Strategy:
    ///   1. If the app is in /System → throw ``.systemApp`` (requires SIP disable)
    ///   2. If the app path is user-writable → call `setIcon` in-process directly
    ///   3. If the app is not writable → fall back to admin-privileged helper

    // ──────────────────────────────────────────
    // MARK: - Icon Padding (macOS Big Sur+ spec)
    // ──────────────────────────────────────────

    /// macOS Big Sur and later expects icons to have ~9.77% transparent
    /// padding on each side (100 px per side on a 1024x1024 canvas).
    /// Icons without this padding appear larger than native apps in Dock.
    ///
    /// This method:
    /// 1. Samples the outermost pixels to detect existing padding
    /// 2. If insufficient padding is detected, creates a new image with
    ///    the icon scaled down to the content area, centered on a transparent canvas
    /// 3. Preserves the original alpha channel and returns the same image
    ///    untouched if padding is already sufficient
    static func ensureMacOSIconPadding(_ image: NSImage) -> NSImage {
        guard image.size.width > 0, image.size.height > 0 else { return image }

        // Check if the icon already has proper edge padding
        if iconHasSufficientPadding(image) {
            logger.info("Icon already has sufficient padding, skipping reprocess")
            return image
        }

        logger.info("Adding macOS-standard padding to icon")

        let size = image.size
        let paddingRatio: CGFloat = 100.0 / 1024.0  // ~9.77%
        let padX = size.width * paddingRatio
        let padY = size.height * paddingRatio
        let contentRect = NSRect(
            x: padX,
            y: padY,
            width: size.width - padX * 2,
            height: size.height - padY * 2
        )

        let padded = NSImage(size: size)
        padded.lockFocus()
        defer { padded.unlockFocus() }

        // Fill with fully transparent background
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        // Draw the original icon scaled to the content area, preserving alpha
        image.draw(
            in: contentRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )

        return padded
    }

    /// Sample the outermost edge pixels of the icon.
    /// Returns true if the icon already has the macOS-standard transparent padding
    /// (edges are mostly transparent), false if the icon content extends to the edges.
    nonisolated private static func iconHasSufficientPadding(_ image: NSImage) -> Bool {
        // Use NSBitmapImageRep which always provides consistent RGBA pixel data,
        // avoiding the byte-order / alpha-location ambiguity of raw CGImage access.
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.bitmapData else {
            return false
        }

        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 20, height > 20 else { return false }

        let bpp = rep.bitsPerPixel / 8
        let rowBytes = rep.bytesPerRow
        // NSBitmapImageRep consistently provides alpha at offset 3 in RGBA
        let alphaIdx = 3

        var transparentSamples = 0
        var totalSamples = 0

        for x in stride(from: 0, to: width, by: 10) {
            let ta = data[rowBytes * 0 + x * bpp + alphaIdx]
            if ta < 10 { transparentSamples += 1 }; totalSamples += 1
            let ba = data[rowBytes * (height - 1) + x * bpp + alphaIdx]
            if ba < 10 { transparentSamples += 1 }; totalSamples += 1
        }
        for y in stride(from: 0, to: height, by: 10) {
            let la = data[rowBytes * y + 0 * bpp + alphaIdx]
            if la < 10 { transparentSamples += 1 }; totalSamples += 1
            let ra = data[rowBytes * y + (width - 1) * bpp + alphaIdx]
            if ra < 10 { transparentSamples += 1 }; totalSamples += 1
        }

        return Double(transparentSamples) / Double(max(totalSamples, 1)) > 0.90
    }

    private func applyIconOnce(app: URL, icon: URL) async throws {
        let appPath = app.path
        guard let rawImage = NSImage(contentsOfFile: icon.path) else {
            throw IconError.missingIcon
        }

        // Apply macOS-standard transparent padding (Big Sur+ spec)
        let image = Self.ensureMacOSIconPadding(rawImage)

        logger.info("Applying icon: \(icon.lastPathComponent) → \(appPath)")

        // ── Check for system-protected apps ──
        if appPath.hasPrefix("/System/") {
            logger.warning("System app detected: \(appPath) — requires SIP disable")
            throw IconError.systemApp("系统应用需要关闭 SIP 才能修改图标")
        }

        // ── First try: direct in-process setIcon ──
        NSWorkspace.shared.setIcon(nil, forFile: appPath, options: [])
        if NSWorkspace.shared.setIcon(image, forFile: appPath, options: []) {
            notifyDock(path: appPath)
            logger.info("Direct setIcon succeeded for \(appPath)")
            return
        }

        // ── Second try: admin-privileged helper ──
        logger.info("Direct setIcon failed for \(appPath), trying admin helper")
        try await applyWithAdmin(app: appPath, icon: icon.path)
    }

    /// Force the Dock to refresh its icon cache for a given path.
    /// The Dock caches app icons independently from the Finder;
    /// `noteFileSystemChanged` alone is not enough — we must `touch`
    /// the bundle to trigger the Dock's file monitoring.
    private func notifyDock(path: String) {
        NSWorkspace.shared.noteFileSystemChanged(path)
        // Touch the app bundle so the Dock's fsevents watcher picks it up
        let attrs: [FileAttributeKey: Any] = [.modificationDate: Date()]
        try? fm.setAttributes(attrs, ofItemAtPath: path)
    }

    /// Clear the custom icon for an app.
    private func clearIcon(app: String) async throws {
        logger.info("Clearing icon for \(app)")

        // Try direct first
        NSWorkspace.shared.setIcon(nil, forFile: app, options: [])
        notifyDock(path: app)

        // Also try admin to be thorough (clearIcon with nil always returns false)
        if !app.hasPrefix("/System/") {
            try? await runAdminCommand("remove", app: app, icon: "")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Admin Fallback
    // ──────────────────────────────────────────────

    /// Run the embedded `seticon` helper tool with admin privileges.
    ///
    /// This is only used when the direct in-process `setIcon` fails,
    /// typically because the app bundle is owned by root or another user.
    private func applyWithAdmin(app: String, icon: String) async throws {
        guard bundleHelperPath() != nil else {
            throw IconError.needsAdmin("辅助工具未嵌入，请使用 in-process 方式")
        }
        try await runAdminCommand("set", app: app, icon: icon)
    }

    /// Find the embedded `seticon` helper tool.
    private func bundleHelperPath() -> String? {
        // First check in the app bundle's Resources
        let candidates = [
            Bundle.main.path(forResource: "seticon", ofType: nil),
            Bundle.main.bundlePath + "/Contents/Resources/seticon",
            Bundle.main.bundlePath + "/Contents/MacOS/seticon",
        ]
        for c in candidates {
            if let p = c, fm.fileExists(atPath: p) {
                return p
            }
        }
        return nil
    }

    /// Run a privileged command via osascript with `with administrator privileges`.
    ///
    /// macOS caches admin credentials for ~5 minutes, so subsequent calls
    /// within that window won't prompt for a password again.
    private func runAdminCommand(_ cmd: String, app: String, icon: String) async throws {
        guard let helper = bundleHelperPath() else {
            throw IconError.needsAdmin("辅助工具未嵌入，无法执行管理员操作")
        }
        let script: String
        if cmd == "set" {
            script = "do shell script \"\(helper) set \\\"\(app)\\\" \\\"\(icon)\\\" 2>&1\" with administrator privileges"
        } else {
            script = "do shell script \"\(helper) remove \\\"\(app)\\\" 2>&1\" with administrator privileges"
        }

        logger.info("Running admin command: \(cmd) for \(app)")

        let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                let out = Pipe()
                let err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                    p.waitUntilExit()
                    let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if p.terminationStatus != 0 {
                        if e.contains("authorization") || e.contains("Authorization") || e.contains("cancel") {
                            cont.resume(throwing: IconError.adminCancelled("授权被取消"))
                        } else {
                            cont.resume(throwing: IconError.needsAdmin(e.isEmpty ? "授权失败" : e))
                        }
                    } else {
                        cont.resume(returning: o)
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        logger.info("Admin command result: \(result)")
        if !result.contains("OK") {
            throw IconError.commandFailed(result)
        }
        notifyDock(path: app)
    }

    // ──────────────────────────────────────────────
    // MARK: - Logging
    // ──────────────────────────────────────────────

    private func appendLog(_ m: String, isError: Bool) {
        logger.info("\(isError ? "[ERROR]" : "[OK]") \(m, privacy: .public)")
        logs.insert(OperationLog(date: Date(), message: m, isError: isError), at: 0)
        logs = Array(logs.prefix(100))
    }
}

// MARK: - Errors

enum IconError: LocalizedError {
    case missingIcon
    case missingBundleIcon
    case commandFailed(String)
    case systemApp(String)
    case needsAdmin(String)
    case adminCancelled(String)

    var errorDescription: String? {
        switch self {
        case .missingIcon:
            return "图标文件不存在或无法加载"
        case .missingBundleIcon:
            return "应用包内没有可替换的图标"
        case .commandFailed(let m):
            return m.isEmpty ? "操作失败" : m
        case .systemApp(let m):
            return m
        case .needsAdmin(let m):
            return m
        case .adminCancelled(let m):
            return m
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let iconSchemeApplied = Notification.Name("ChangeIcon.iconSchemeApplied")
}
