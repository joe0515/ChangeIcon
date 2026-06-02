import AppKit
import Foundation

@MainActor
final class IconApplier: ObservableObject {
    @Published private(set) var isApplying = false
    @Published var logs: [OperationLog] = []
    @Published var currentProgress: (current: Int, total: Int)?

    private let fileManager = FileManager.default
    private let backupFolder: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        backupFolder = support.appendingPathComponent("ChangeIcon/Backups", isDirectory: true)
        try? fileManager.createDirectory(at: backupFolder, withIntermediateDirectories: true)
    }

    // MARK: - Auto Apply

    func applyIfNeeded(schemes: [IconScheme], appearance: AppearanceMode, force: Bool = false) async {
        let targets = schemes.filter { scheme in
            scheme.enabled && scheme.iconURL(for: appearance) != nil && (force || scheme.lastAppliedMode != appearance)
        }
        guard !targets.isEmpty else { return }
        await apply(targets, appearance: appearance)
    }

    // MARK: - Apply with Progress

    func apply(_ schemes: [IconScheme], appearance: AppearanceMode) async {
        isApplying = true
        currentProgress = (0, schemes.count)
        defer {
            isApplying = false
            currentProgress = nil
        }

        for (index, scheme) in schemes.enumerated() {
            currentProgress = (index + 1, schemes.count)

            guard let iconURL = scheme.iconURL(for: appearance) else {
                append("跳过 \(scheme.appName)：没有设置\(appearance.title)图标", isError: true)
                continue
            }

            do {
                let backupURL = try backupOriginalIconIfNeeded(for: scheme)
                try replaceIcon(for: scheme.appURL, with: iconURL, shape: scheme.iconShape)
                notifyLaunchServices(appURL: scheme.appURL)
                append("已为 \(scheme.appName) 应用\(appearance.title)图标", isError: false)
                NotificationCenter.default.post(
                    name: .iconSchemeApplied,
                    object: nil,
                    userInfo: ["id": scheme.id, "mode": appearance, "backupURL": backupURL as Any]
                )
            } catch {
                append("无法更新 \(scheme.appName)：\(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: - Restore

    func restore(_ scheme: IconScheme, backupURL: URL?) async {
        guard let backupURL else {
            append("没有找到 \(scheme.appName) 的原始图标备份", isError: true)
            return
        }
        isApplying = true
        defer { isApplying = false }

        do {
            try replaceIcon(for: scheme.appURL, with: backupURL, shape: .none)
            notifyLaunchServices(appURL: scheme.appURL)
            append("已恢复 \(scheme.appName) 的原始图标", isError: false)
        } catch {
            append("恢复 \(scheme.appName) 失败：\(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Refresh Icon Cache

    func refreshIconCache(for appURLs: [URL]) async {
        isApplying = true
        currentProgress = (0, appURLs.count)
        defer {
            isApplying = false
            currentProgress = nil
        }

        for (index, appURL) in appURLs.enumerated() {
            currentProgress = (index + 1, appURLs.count)
            notifyLaunchServices(appURL: appURL)
        }
        append("已刷新 \(appURLs.count) 个应用的图标缓存", isError: false)
    }

    // MARK: - Backup

    private func backupOriginalIconIfNeeded(for scheme: IconScheme) throws -> URL? {
        if let backup = scheme.originalIconBackupURL, fileManager.fileExists(atPath: backup.path) {
            return backup
        }
        let iconDestination = try iconDestinationURL(for: scheme.appURL)
        guard fileManager.fileExists(atPath: iconDestination.path) else { return nil }

        let safeName = scheme.appURL.path
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "-")
        let backupURL = backupFolder.appendingPathComponent("\(safeName)-original.icns")
        if !fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.copyItem(at: iconDestination, to: backupURL)
        }
        return backupURL
    }

    // MARK: - Replace Icon

    private func replaceIcon(for appURL: URL, with sourceIconURL: URL, shape: IconShape) throws {
        let destination = try iconDestinationURL(for: appURL)
        let icnsURL = try preparedICNS(from: sourceIconURL, shape: shape)
        try privilegedCopy(source: icnsURL, destination: destination)
        try privilegedTouch(appURL)
    }

    // MARK: - Icon Destination

    private func iconDestinationURL(for appURL: URL) throws -> URL {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard
            let info = NSDictionary(contentsOf: infoURL),
            let rawName = (info["CFBundleIconFile"] as? String) ?? (info["CFBundleIconName"] as? String)
        else {
            throw IconError.missingBundleIcon
        }

        let filename = rawName.hasSuffix(".icns") ? rawName : "\(rawName).icns"
        return appURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent(filename)
    }

    // MARK: - ICNS Preparation with Shape Mask

    private func preparedICNS(from sourceURL: URL, shape: IconShape) throws -> URL {
        // If no shape processing needed and source is already ICNS, return directly
        if shape == .none && sourceURL.pathExtension.lowercased() == "icns" {
            return sourceURL
        }

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ChangeIcon-\(UUID().uuidString)", isDirectory: true)
        let iconset = tempRoot.appendingPathComponent("icon.iconset", isDirectory: true)
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

        // Generate all required sizes
        let sizes: [(Int, Int, String)] = [
            (16, 1, "icon_16x16.png"),
            (32, 2, "icon_16x16@2x.png"),
            (32, 1, "icon_32x32.png"),
            (64, 2, "icon_32x32@2x.png"),
            (128, 1, "icon_128x128.png"),
            (256, 2, "icon_128x128@2x.png"),
            (256, 1, "icon_256x256.png"),
            (512, 2, "icon_256x256@2x.png"),
            (512, 1, "icon_512x512.png"),
            (1024, 2, "icon_512x512@2x.png"),
        ]

        for (size, _, name) in sizes {
            let output = iconset.appendingPathComponent(name)
            try run("/usr/bin/sips", arguments: [
                "-z", "\(size)", "\(size)",
                sourceURL.path,
                "--out", output.path
            ])

            // Apply shape mask if needed
            if shape != .none {
                try applyShapeMask(to: output, size: CGFloat(size), shape: shape)
            }
        }

        let icnsURL = tempRoot.appendingPathComponent("icon.icns")
        try run("/usr/bin/iconutil", arguments: [
            "-c", "icns",
            iconset.path,
            "-o", icnsURL.path
        ])
        return icnsURL
    }

    // MARK: - Shape Mask Application

    private func applyShapeMask(to pngURL: URL, size: CGFloat, shape: IconShape) throws {
        guard let image = NSImage(contentsOf: pngURL) else { return }

        let maskedImage = NSImage(size: NSSize(width: size, height: size))
        maskedImage.lockFocus()

        // Create clipping path
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let cornerRadius = shape.cornerRadius(for: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.addClip()

        // Draw image inside clipping path
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)

        maskedImage.unlockFocus()

        // Save back to same file
        guard
            let tiffData = maskedImage.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else { return }

        try pngData.write(to: pngURL)
    }

    // MARK: - Privileged Operations

    private func privilegedCopy(source: URL, destination: URL) throws {
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            try runAsAdministrator(script: """
            cp '\(shellEscaped(source.path))' '\(shellEscaped(destination.path))'
            chmod 644 '\(shellEscaped(destination.path))'
            """)
        }
    }

    private func privilegedTouch(_ appURL: URL) throws {
        do {
            let now = Date()
            try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: appURL.path)
            try? fileManager.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: appURL.appendingPathComponent("Contents/Info.plist").path
            )
        } catch {
            try runAsAdministrator(script: """
            touch '\(shellEscaped(appURL.path))'
            touch '\(shellEscaped(appURL.appendingPathComponent("Contents/Info.plist").path))'
            """)
        }
    }

    // MARK: - Launch Services Notification

    private func notifyLaunchServices(appURL: URL) {
        NSWorkspace.shared.noteFileSystemChanged(appURL.path)
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if fileManager.fileExists(atPath: lsregister) {
            _ = try? run(lsregister, arguments: ["-f", appURL.path])
        }
        _ = try? run("/usr/bin/qlmanage", arguments: ["-r", "cache"])
        _ = try? run("/usr/bin/killall", arguments: ["Dock"])
        _ = try? run("/usr/bin/killall", arguments: ["Finder"])
        _ = try? run("/usr/bin/killall", arguments: ["SystemUIServer"])
    }

    // MARK: - Process Execution

    private func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "命令执行失败"
            throw IconError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func runAsAdministrator(script: String) throws {
        let escaped = script.replacingOccurrences(of: "\"", with: "\\\"")
        try run("/usr/bin/osascript", arguments: [
            "-e",
            "do shell script \"\(escaped)\" with administrator privileges"
        ])
    }

    // MARK: - Helpers

    private func shellEscaped(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func append(_ message: String, isError: Bool) {
        logs.insert(OperationLog(date: Date(), message: message, isError: isError), at: 0)
        logs = Array(logs.prefix(100))
    }
}

// MARK: - IconError

enum IconError: LocalizedError {
    case missingBundleIcon
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBundleIcon:
            "目标应用没有声明可替换的 bundle 图标"
        case .commandFailed(let message):
            message.isEmpty ? "命令执行失败" : message
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let iconSchemeApplied = Notification.Name("ChangeIcon.iconSchemeApplied")
}
