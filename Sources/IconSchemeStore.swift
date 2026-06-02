import AppKit
import Foundation

// MARK: - Undo State Snapshot

private struct SchemesSnapshot {
    let schemes: [IconScheme]
}

@MainActor
final class IconSchemeStore: ObservableObject {
    @Published var schemes: [IconScheme] = [] {
        didSet { save() }
    }
    @Published var importSummary = ""
    @Published var canUndo = false

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileURL: URL
    private var undoStack: [SchemesSnapshot] = []
    private let maxUndoStack = 30

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("ChangeIcon", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("schemes.json")
        load()
    }

    // MARK: - Undo

    func pushUndo() {
        let snapshot = SchemesSnapshot(schemes: schemes)
        undoStack.append(snapshot)
        if undoStack.count > maxUndoStack {
            undoStack.removeFirst()
        }
        canUndo = !undoStack.isEmpty
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        schemes = snapshot.schemes
        canUndo = !undoStack.isEmpty
        importSummary = "已撤销上次操作。"
    }

    // MARK: - CRUD

    func addApp(_ url: URL) {
        guard url.pathExtension.lowercased() == "app" else { return }
        guard !schemes.contains(where: { $0.appURL.standardizedFileURL == url.standardizedFileURL }) else { return }
        pushUndo()
        schemes.append(IconScheme(appURL: url))
    }

    func remove(_ scheme: IconScheme) {
        pushUndo()
        schemes.removeAll { $0.id == scheme.id }
    }

    func update(_ scheme: IconScheme) {
        guard let index = schemes.firstIndex(where: { $0.id == scheme.id }) else { return }
        pushUndo()
        schemes[index] = scheme
    }

    func setIcon(_ iconURL: URL, for scheme: IconScheme, mode: AppearanceMode) {
        guard let index = schemes.firstIndex(where: { $0.id == scheme.id }) else { return }
        pushUndo()
        switch mode {
        case .light:
            schemes[index].lightIconURL = iconURL
        case .dark:
            schemes[index].darkIconURL = iconURL
        }
    }

    func markApplied(_ schemeID: UUID, mode: AppearanceMode, backupURL: URL?) {
        guard let index = schemes.firstIndex(where: { $0.id == schemeID }) else { return }
        schemes[index].lastAppliedMode = mode
        if let backupURL, schemes[index].originalIconBackupURL == nil {
            schemes[index].originalIconBackupURL = backupURL
        }
    }

    func restoreBackupURL(for scheme: IconScheme) -> URL? {
        schemes.first(where: { $0.id == scheme.id })?.originalIconBackupURL
    }

    // MARK: - Bulk Actions

    func applyAll(appearance: AppearanceMode, applier: IconApplier) async {
        let targets = schemes.filter { scheme in
            scheme.enabled && scheme.iconURL(for: appearance) != nil
        }
        guard !targets.isEmpty else {
            importSummary = "没有可应用的方案。"
            return
        }
        await applier.apply(targets, appearance: appearance)
        importSummary = "已批量应用 \(targets.count) 个方案。"
    }

    // MARK: - Export / Import

    func exportSchemes(to url: URL) {
        guard let data = try? encoder.encode(schemes) else {
            importSummary = "导出失败：无法编码方案数据。"
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            importSummary = "已导出 \(schemes.count) 个方案。"
        } catch {
            importSummary = "导出失败：\(error.localizedDescription)"
        }
    }

    func importSchemes(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            importSummary = "导入失败：无法读取文件。"
            return
        }
        guard let imported = try? decoder.decode([IconScheme].self, from: data) else {
            importSummary = "导入失败：文件格式不正确。"
            return
        }

        pushUndo()

        var added = 0
        for scheme in imported {
            guard !schemes.contains(where: { $0.appURL.standardizedFileURL == scheme.appURL.standardizedFileURL })
            else { continue }
            schemes.append(scheme)
            added += 1
        }

        importSummary = added > 0
            ? "已导入 \(added) 个方案（共 \(imported.count) 个）。"
            : "所有方案已存在，没有新增。"
    }

    // MARK: - Icon Pack Import

    func importIconPack(from folderURL: URL) {
        let files = iconFiles(in: folderURL)
        guard !files.isEmpty else {
            importSummary = "没有在图标包里找到支持的图片文件。"
            return
        }

        pushUndo()

        var updated = schemes
        var matchedCount = 0

        for index in updated.indices {
            let appKey = Self.normalized(updated[index].appName)
            let matches = files.filter { file in
                let key = Self.normalized(file.deletingPathExtension().lastPathComponent)
                return key.contains(appKey) || appKey.contains(key)
            }

            guard !matches.isEmpty else { continue }

            if let light = Self.bestIcon(in: matches, for: .light) {
                updated[index].lightIconURL = light
                matchedCount += 1
            }
            if let dark = Self.bestIcon(in: matches, for: .dark) {
                updated[index].darkIconURL = dark
                matchedCount += 1
            }
        }

        schemes = updated
        importSummary = matchedCount == 0
            ? "已扫描 \(files.count) 个图标文件，但没有匹配到当前应用列表。"
            : "已导入 \(matchedCount) 个图标配置。"
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        schemes = (try? decoder.decode([IconScheme].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? encoder.encode(schemes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Helpers

    private func iconFiles(in folderURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return Self.isSupportedIcon(url) ? url : nil
        }
    }

    private static func bestIcon(in urls: [URL], for mode: AppearanceMode) -> URL? {
        let preferred = urls.first { url in
            let name = normalized(url.deletingPathExtension().lastPathComponent)
            switch mode {
            case .light:
                return name.contains("light") || name.contains("day") || name.contains("sun") || name.contains("浅色") || name.contains("亮色")
            case .dark:
                return name.contains("dark") || name.contains("night") || name.contains("moon") || name.contains("深色") || name.contains("暗色")
            }
        }
        return preferred ?? urls.first
    }

    private static func isSupportedIcon(_ url: URL) -> Bool {
        ["icns", "png", "jpg", "jpeg", "tif", "tiff"].contains(url.pathExtension.lowercased())
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
    }
}
