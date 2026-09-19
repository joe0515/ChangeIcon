import Foundation
import OSLog

private let logger = Logger(subsystem: "com.local.ChangeIcon", category: "Backup")

// MARK: - Backup Errors

enum BackupError: LocalizedError {
    case emptyBackup
    case invalidManifest
    case unsupportedVersion(Int)
    case compressionFailed(String)
    case extractionFailed(String)
    case iconCopyFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyBackup:
            return "没有可备份的图标方案"
        case .invalidManifest:
            return "备份文件格式不正确（缺少清单）"
        case .unsupportedVersion(let v):
            return "备份版本过新（v\(v)），请升级应用后再导入"
        case .compressionFailed(let m):
            return "打包失败：\(m)"
        case .extractionFailed(let m):
            return "解压失败：\(m)"
        case .iconCopyFailed(let m):
            return "图标文件复制失败：\(m)"
        }
    }
}

// MARK: - Backup Manager

/// 用户数据备份：把「软件信息 + 深浅色图标文件」打包为单个 `.changeiconbackup`
/// 归档（本质为 zip），支持导出与导入。
///
/// 归档内部结构：
/// ```
/// <备份名>.changeiconbackup
/// ├── manifest.json          # 软件信息清单（图标为归档内相对路径）
/// └── icons/
///     ├── <app>-light.png
///     └── <app>-dark.png
/// ```
///
/// 图标统一命名为 `<sanitized-appName>-light/dark.<ext>`，与所属软件、外观
/// 模式一一对应。导入时图标被复制到 Application Support 的持久化目录，
/// 避免引用临时解压目录而失效。
@MainActor
final class BackupManager: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var summary = ""

    private let fm = FileManager.default

    // MARK: - Export

    /// 导出一份完整备份到指定位置。
    /// - Parameters:
    ///   - schemes: 当前全部方案（仅导出至少设置了一个图标的）
    ///   - url: 目标归档文件路径（`.changeiconbackup`）
    func exportBackup(schemes: [IconScheme], to url: URL) async {
        guard !isWorking else { return }
        isWorking = true
        summary = ""
        defer { isWorking = false }

        let valid = schemes.filter { $0.lightIconURL != nil || $0.darkIconURL != nil }
        guard !valid.isEmpty else {
            summary = "没有可备份的图标方案。"
            return
        }

        let workDir = Self.makeTempDir()
        let iconsDir = workDir.appendingPathComponent("icons", isDirectory: true)
        do {
            try fm.createDirectory(at: iconsDir, withIntermediateDirectories: true)

            var entries: [BackupSchemeEntry] = []
            var usedNames = Set<String>()

            for scheme in valid {
                var entry = BackupSchemeEntry(
                    appName: scheme.appName,
                    bundleID: scheme.cachedBundleID,
                    appPath: scheme.appURL.path,
                    iconShape: scheme.iconShape,
                    enabled: scheme.enabled,
                    lightIcon: nil,
                    darkIcon: nil
                )

                if let light = scheme.lightIconURL {
                    let ext = light.pathExtension.lowercased()
                    if !ext.isEmpty {
                        let name = Self.uniqueIconName(
                            base: "\(IconStorage.sanitized(scheme.appName))-light", ext: ext, used: &usedNames
                        )
                        let dest = iconsDir.appendingPathComponent(name)
                        do {
                            try fm.copyItem(at: light, to: dest)
                            entry.lightIcon = "icons/\(name)"
                        } catch {
                            logger.error("复制浅色图标失败: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }

                if let dark = scheme.darkIconURL {
                    let ext = dark.pathExtension.lowercased()
                    if !ext.isEmpty {
                        let name = Self.uniqueIconName(
                            base: "\(IconStorage.sanitized(scheme.appName))-dark", ext: ext, used: &usedNames
                        )
                        let dest = iconsDir.appendingPathComponent(name)
                        do {
                            try fm.copyItem(at: dark, to: dest)
                            entry.darkIcon = "icons/\(name)"
                        } catch {
                            logger.error("复制深色图标失败: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }

                entries.append(entry)
            }

            let manifest = BackupManifest(version: BackupManifest.currentVersion, exportedAt: Date(), schemes: entries)
            let manifestData = try Self.manifestEncoder().encode(manifest)
            try manifestData.write(to: workDir.appendingPathComponent("manifest.json"), options: .atomic)

            // 打包为 zip 归档
            try await Self.runDitto(arguments: ["-c", "-k", workDir.path, url.path])

            summary = "已导出 \(entries.count) 个方案（含深浅色图标）。"
            logger.info("导出备份成功：\(entries.count) 个方案 → \(url.path, privacy: .public)")
        } catch let error as BackupError {
            summary = "导出失败：\(error.errorDescription ?? error.localizedDescription)"
            logger.error("导出失败: \(error.localizedDescription, privacy: .public)")
        } catch {
            summary = "导出失败：\(error.localizedDescription)"
            logger.error("导出失败: \(error.localizedDescription, privacy: .public)")
        }

        try? fm.removeItem(at: workDir)
    }

    // MARK: - Import

    /// 从备份文件恢复，返回重建好的 `IconScheme` 数组（图标已落到持久化目录）。
    /// 返回 `nil` 表示导入失败（`summary` 会说明原因）。
    func importBackup(from url: URL) async -> [IconScheme]? {
        guard !isWorking else { return nil }
        isWorking = true
        summary = ""
        defer { isWorking = false }

        let workDir = Self.makeTempDir()
        defer { try? fm.removeItem(at: workDir) }

        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            try await Self.runDitto(arguments: ["-x", "-k", url.path, workDir.path])

            let manifestURL = workDir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? Self.manifestDecoder().decode(BackupManifest.self, from: data) else {
                throw BackupError.invalidManifest
            }

            guard manifest.version <= BackupManifest.currentVersion else {
                throw BackupError.unsupportedVersion(manifest.version)
            }

            var schemes: [IconScheme] = []
            for entry in manifest.schemes {
                var lightURL: URL?
                var darkURL: URL?

                // 固化图标到统一目录并统一命名（与常规设置图标一致）
                if let rel = entry.lightIcon {
                    lightURL = IconStorage.persist(
                        workDir.appendingPathComponent(rel), appName: entry.appName, mode: .light
                    )
                }
                if let rel = entry.darkIcon {
                    darkURL = IconStorage.persist(
                        workDir.appendingPathComponent(rel), appName: entry.appName, mode: .dark
                    )
                }

                let scheme = IconScheme(
                    appURL: URL(fileURLWithPath: entry.appPath),
                    lightIconURL: lightURL,
                    darkIconURL: darkURL,
                    enabled: entry.enabled,
                    lastAppliedMode: nil,
                    originalIconBackupURL: nil,
                    iconShape: entry.iconShape,
                    cachedBundleID: entry.bundleID
                )
                schemes.append(scheme)
            }

            summary = "已从备份读取 \(schemes.count) 个方案。"
            logger.info("导入备份成功：\(schemes.count) 个方案")
            return schemes
        } catch let error as BackupError {
            summary = "导入失败：\(error.errorDescription ?? error.localizedDescription)"
            logger.error("导入失败: \(error.localizedDescription, privacy: .public)")
        } catch {
            summary = "导入失败：\(error.localizedDescription)"
            logger.error("导入失败: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    // MARK: - Static Helpers

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ChangeIconBackup-\(UUID().uuidString)", isDirectory: true)
    }

    /// 生成不重复的图标文件名。
    private static func uniqueIconName(base: String, ext: String, used: inout Set<String>) -> String {
        var candidate = "\(base).\(ext)"
        var counter = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(counter).\(ext)"
            counter += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func manifestEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func manifestDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 调用系统 `ditto` 完成 zip 压缩（`-c -k`）或解压（`-x -k`）。
    private static func runDitto(arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = arguments

            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()

            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let isCompress = arguments.first == "-c"
                    let error: BackupError = isCompress
                        ? .compressionFailed(msg)
                        : .extractionFailed(msg)
                    cont.resume(throwing: error)
                }
            }

            do {
                try p.run()
            } catch {
                cont.resume(throwing: BackupError.compressionFailed(error.localizedDescription))
            }
        }
    }
}
