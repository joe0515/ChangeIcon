import AppKit
import Foundation

@MainActor
final class IconLibrary: ObservableObject {
    static let shared = IconLibrary()

    @Published private(set) var iconFiles: [URL] = []
    @Published private(set) var isReady = false

    private var nameIndex: [String: [URL]] = [:]
    private var allKeys: [String] = []
    private let fileManager = FileManager.default

    private init() {
        loadIcons()
    }

    var iconsDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("icons", isDirectory: true)
    }

    func reload() {
        nameIndex.removeAll()
        allKeys.removeAll()
        iconFiles.removeAll()
        loadIcons()
    }

    private func loadIcons() {
        guard let dir = iconsDir, fileManager.fileExists(atPath: dir.path) else {
            isReady = true
            return
        }

        guard let enumerator = fileManager.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            isReady = true
            return
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard ["png", "jpg", "jpeg", "icns", "tiff", "tif"].contains(url.pathExtension.lowercased()) else { continue }
            files.append(url)
        }

        iconFiles = files.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        for file in iconFiles {
            let name = IconLibrary.normalizedKey(file.deletingPathExtension().lastPathComponent)
            var entries = nameIndex[name] ?? []
            entries.append(file)
            nameIndex[name] = entries
        }

        allKeys = Array(nameIndex.keys)
        isReady = true
    }

    func findIcon(for appName: String) -> URL? {
        findMatches(for: appName).first
    }

    func findMatches(for appName: String) -> [URL] {
        guard isReady, !allKeys.isEmpty else { return [] }

        let normalizedApp = IconLibrary.normalizedKey(appName)
        guard !normalizedApp.isEmpty else { return [] }

        var seen = Set<URL>()

        if let exact = nameIndex[normalizedApp] {
            for url in exact { seen.insert(url) }
        }

        for key in allKeys where key != normalizedApp {
            if key.contains(normalizedApp) || normalizedApp.contains(key) {
                if let urls = nameIndex[key] {
                    for url in urls { seen.insert(url) }
                }
            }
        }

        return Array(seen)
    }

    func allIconNames() -> [String] {
        iconFiles.map { $0.deletingPathExtension().lastPathComponent }
    }

    static func normalizedKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
    }
}
