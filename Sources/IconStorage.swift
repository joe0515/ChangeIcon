import Foundation
import OSLog

/// 图标固化存储。
///
/// 当用户为某个应用设置图标时，图标文件会被复制到固定的持久化目录
/// `~/Library/Application Support/ChangeIcon/AppliedIcons/`，并以统一规则
/// 命名 `<sanitized-appName>-light/dark.<扩展名>`。这样：
///
/// 1. 方案不再依赖用户原始图标文件的位置（移动/删除原文件不影响已设置的图标）；
/// 2. 图标命名与备份导出的命名完全一致，固化与备份共用同一套规则。
enum IconStorage {
    private static let logger = Logger(subsystem: "com.local.ChangeIcon", category: "IconStorage")

    /// 固化图标的固定保存目录。
    static var appliedIconsDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ChangeIcon/AppliedIcons", isDirectory: true)
    }

    /// 统一图标文件名（与备份命名一致）：`<sanitized-appName>-light/dark.<ext>`。
    static func iconName(appName: String, mode: AppearanceMode, ext: String) -> String {
        "\(sanitized(appName))-\(mode == .light ? "light" : "dark").\(ext)"
    }

    /// 文件系统安全命名：剔除路径分隔符与非法字符，保留中英文与数字。
    static func sanitized(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        var result = ""
        for scalar in name.unicodeScalars {
            if invalid.contains(scalar) || CharacterSet.whitespaces.contains(scalar) {
                result.append("_")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.isEmpty ? "App" : result
    }

    /// 固化图标：把 `source` 复制到固定目录并统一命名，返回固化后的 URL。
    ///
    /// - 若 `source` 已位于固定目录且命名一致，则直接返回（幂等）；
    /// - 否则覆盖同名的旧文件后复制。
    /// - 失败时返回 `nil`（调用方可回退到原始 URL，保证功能不退化）。
    @discardableResult
    static func persist(_ source: URL, appName: String, mode: AppearanceMode) -> URL? {
        let ext = source.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }

        let dest = appliedIconsDir.appendingPathComponent(iconName(appName: appName, mode: mode, ext: ext))
        let fm = FileManager.default

        // 幂等：源文件已是固化位置
        if source.standardizedFileURL == dest.standardizedFileURL {
            return dest
        }

        do {
            try fm.createDirectory(at: appliedIconsDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            try fm.copyItem(at: source, to: dest)
            return dest
        } catch {
            logger.error("固化图标失败: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
