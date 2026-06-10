import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.local.ChangeIcon", category: "IconApplier")

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

    func applyIfNeeded(schemes: [IconScheme], appearance: AppearanceMode, force: Bool = false) async {
        let targets = schemes.filter { s in
            guard s.enabled, let _ = s.iconURL(for: appearance) else { return false }
            return force || s.lastAppliedMode != appearance
        }
        logger.info("applyIfNeeded: mode=\(appearance.title) targets=\(targets.count)")
        guard !targets.isEmpty else { return }
        await apply(targets, appearance: appearance)
    }

    func apply(_ schemes: [IconScheme], appearance: AppearanceMode) async {
        isApplying = true
        currentProgress = (0, schemes.count)
        defer {
            isApplying = false
            currentProgress = nil
        }
        needsPermissionSetup = false
        permissionGuideMessage = ""
        var appliedPaths: [String] = []

        // ── First pass: direct setIcon for each app ──
        var adminBatch: [(app: String, icon: String, name: String)] = []

        for (i, scheme) in schemes.enumerated() {
            currentProgress = (i + 1, schemes.count)
            guard let iconURL = scheme.iconURL(for: appearance) else { continue }

            do {
                try await applyIconOnce(app: scheme.appURL, icon: iconURL)
                appliedPaths.append(scheme.appURL.path)
                appendLog("已为 \(scheme.appName) 应用\(appearance.title)图标", isError: false)
                NotificationCenter.default.post(
                    name: .iconSchemeApplied, object: nil,
                    userInfo: ["id": scheme.id, "mode": appearance]
                )
            } catch let error as IconError {
                switch error {
                case .systemApp:
                    appendLog("\(scheme.appName): 系统应用需关闭 SIP", isError: true)
                    if !needsPermissionSetup {
                        needsPermissionSetup = true
                        permissionGuideMessage = "系统应用（如 Finder、Safari）需要关闭 SIP 才能更换图标。\n\n操作指引：重启 Mac → 按住 Cmd+R 进入恢复模式 → 打开终端 → 运行 `csrutil disable` → 重启。"
                    }
                case .needsAdmin:
                    adminBatch.append((app: scheme.appURL.path, icon: iconURL.path, name: scheme.appName))
                case .adminCancelled:
                    appendLog("\(scheme.appName): 管理员授权被取消", isError: true)
                default:
                    appendLog("\(scheme.appName): \(error.errorDescription ?? "操作失败")", isError: true)
                }
            } catch {
                appendLog("\(scheme.appName): \(error.localizedDescription)", isError: true)
            }
        }

        // ── Second pass: batch admin execution ──
        if !adminBatch.isEmpty {
            do {
                let names = adminBatch.map(\.name)
                appendLog("正在通过管理员授权处理 \(names.joined(separator: "、")) ...", isError: false)
                try await runBatchAdminCommand(adminBatch)
                for item in adminBatch {
                    appliedPaths.append(item.app)
                    appendLog("已为 \(item.name) 应用\(appearance.title)图标", isError: false)
                }
            } catch let error as IconError {
                appendLog("批量管理员操作: \(error.errorDescription ?? "未知错误")", isError: true)
            } catch {
                appendLog("批量管理员操作失败: \(error.localizedDescription)", isError: true)
            }
        }

        if !appliedPaths.isEmpty {
            for path in appliedPaths {
                NSWorkspace.shared.noteFileSystemChanged(path)
            }
            let attrs: [FileAttributeKey: Any] = [.modificationDate: Date()]
            for path in appliedPaths {
                try? FileManager.default.setAttributes(attrs, ofItemAtPath: path)
            }
        }
    }

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

    private func applyIconOnce(app: URL, icon: URL) async throws {
        let appPath = app.path
        guard let rawImage = NSImage(contentsOfFile: icon.path) else {
            throw IconError.missingIcon
        }
        let image = Self.ensureMacOSIconPadding(rawImage)
        logger.info("Applying icon: \(icon.lastPathComponent) → \(appPath)")

        if appPath.hasPrefix("/System/") {
            throw IconError.systemApp("系统应用需要关闭 SIP 才能修改图标")
        }

        if NSWorkspace.shared.setIcon(image, forFile: appPath, options: []) {
            return
        }
        throw IconError.needsAdmin(appPath)
    }

    // ──────────────────────────────────────────────
    // MARK: - Icon Padding (macOS Big Sur+ spec)
    // ──────────────────────────────────────────────

    static func ensureMacOSIconPadding(_ image: NSImage) -> NSImage {
        guard image.size.width > 0, image.size.height > 0 else { return image }
        if iconHasSufficientPadding(image) { return image }

        let size = image.size
        let paddingRatio: CGFloat = 100.0 / 1024.0
        let padX = size.width * paddingRatio
        let padY = size.height * paddingRatio
        let contentRect = NSRect(x: padX, y: padY, width: size.width - padX * 2, height: size.height - padY * 2)

        let padded = NSImage(size: size)
        padded.lockFocus()
        defer { padded.unlockFocus() }
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: contentRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        return padded
    }

    nonisolated private static func iconHasSufficientPadding(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.bitmapData else { return false }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        guard width > 20, height > 20 else { return false }
        let bpp = rep.bitsPerPixel / 8, rowBytes = rep.bytesPerRow, alphaIdx = 3

        var transparentSamples = 0, totalSamples = 0
        for x in stride(from: 0, to: width, by: 10) {
            if data[rowBytes * 0 + x * bpp + alphaIdx] < 10 { transparentSamples += 1 }; totalSamples += 1
            if data[rowBytes * (height - 1) + x * bpp + alphaIdx] < 10 { transparentSamples += 1 }; totalSamples += 1
        }
        for y in stride(from: 0, to: height, by: 10) {
            if data[rowBytes * y + 0 * bpp + alphaIdx] < 10 { transparentSamples += 1 }; totalSamples += 1
            if data[rowBytes * y + (width - 1) * bpp + alphaIdx] < 10 { transparentSamples += 1 }; totalSamples += 1
        }
        return Double(transparentSamples) / Double(max(totalSamples, 1)) > 0.90
    }

    private func clearIcon(app: String) async throws {
        NSWorkspace.shared.setIcon(nil, forFile: app, options: [])
        notifyDock(path: app)
    }

    private func notifyDock(path: String) {
        NSWorkspace.shared.noteFileSystemChanged(path)
        let attrs: [FileAttributeKey: Any] = [.modificationDate: Date()]
        try? fm.setAttributes(attrs, ofItemAtPath: path)
    }

    // ──────────────────────────────────────────────
    // MARK: - Batch Admin
    // ──────────────────────────────────────────────

    private func runBatchAdminCommand(_ items: [(app: String, icon: String, name: String)]) async throws {
        guard let helper = bundleHelperPath() else {
            throw IconError.needsAdmin("辅助工具未嵌入")
        }

        let uid = getuid()
        let gid = getgid()

        var lines = ["#!/bin/bash", "set -e"]
        for item in items {
            // Pass user uid/gid so the helper (running as root) can chown
            lines.append("'\(helper)' set '\(item.app)' '\(item.icon)' \(uid) \(gid) || true")
        }

        let tmpDir = FileManager.default.temporaryDirectory
        let scriptURL = tmpDir.appendingPathComponent("changeicon_batch.sh")
        try lines.joined(separator: "\n").write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let appNames = items.map(\.name).joined(separator: "、")
        let osaScript = "do shell script \"bash '\(scriptURL.path)' 2>&1\" with administrator privileges with prompt \"ChangeIcon 需要管理员权限来修改以下应用的图标：\(appNames)\""
        logger.info("Batch admin: \(items.count) apps")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", osaScript]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            p.terminationHandler = { proc in
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationStatus != 0 {
                    if e.contains("authorization") || e.contains("cancel") || e.contains("用户取消") {
                        cont.resume(throwing: IconError.adminCancelled("管理员授权被取消"))
                    } else {
                        cont.resume(throwing: IconError.needsAdmin(e.isEmpty ? "授权执行失败" : e))
                    }
                } else {
                    cont.resume()
                }
            }
            do { try p.run() } catch {
                cont.resume(throwing: IconError.needsAdmin("无法启动授权进程"))
            }
        }
    }

    private func bundleHelperPath() -> String? {
        for c in [
            Bundle.main.path(forResource: "seticon", ofType: nil),
            Bundle.main.bundlePath + "/Contents/Resources/seticon",
            Bundle.main.bundlePath + "/Contents/MacOS/seticon"
        ] {
            if let p = c, fm.fileExists(atPath: p) { return p }
        }
        return nil
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
    case missingIcon, missingBundleIcon, commandFailed(String), systemApp(String), needsAdmin(String), adminCancelled(String)

    var errorDescription: String? {
        switch self {
        case .missingIcon: return "图标文件不存在或无法加载"
        case .missingBundleIcon: return "应用包内没有可替换的图标"
        case .commandFailed(let m): return m.isEmpty ? "操作失败" : m
        case .systemApp(let m): return m
        case .needsAdmin(let m): return m
        case .adminCancelled(let m): return m
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let iconSchemeApplied = Notification.Name("ChangeIcon.iconSchemeApplied")
}
