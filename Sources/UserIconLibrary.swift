import AppKit
import Foundation

@MainActor
final class UserIconLibrary: ObservableObject {
    static let shared = UserIconLibrary()

    @Published private(set) var lightIcons: [URL] = []
    @Published private(set) var darkIcons: [URL] = []
    @Published private(set) var isReady = false

    private let fileManager = FileManager.default
    private let lightDir: URL
    private let darkDir: URL

    private init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        lightDir = support.appendingPathComponent("ChangeIcon/UserIcons/Light", isDirectory: true)
        darkDir = support.appendingPathComponent("ChangeIcon/UserIcons/Dark", isDirectory: true)
        try? fileManager.createDirectory(at: lightDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: darkDir, withIntermediateDirectories: true)
        loadIcons()
    }

    /// Copy an icon to the library
    func addIcon(from sourceURL: URL, mode: AppearanceMode) -> URL? {
        let dir = mode == .light ? lightDir : darkDir
        let ext = sourceURL.pathExtension.lowercased()
        let name = sourceURL.deletingPathExtension().lastPathComponent
        let dest = dir.appendingPathComponent("\(name).\(ext)")

        // Skip if already in library
        let icons = mode == .light ? lightIcons : darkIcons
        if dest == sourceURL || (icons.contains(dest) && fileManager.fileExists(atPath: dest.path)) {
            if !icons.contains(dest) {
                addToList(dest, mode: mode)
            }
            return dest
        }

        // Handle duplicate names
        var finalDest = dest
        var counter = 1
        while fileManager.fileExists(atPath: finalDest.path) && finalDest != sourceURL {
            finalDest = dir.appendingPathComponent("\(name)-\(counter).\(ext)")
            counter += 1
        }

        do {
            if finalDest != sourceURL {
                if fileManager.fileExists(atPath: finalDest.path) {
                    try fileManager.removeItem(at: finalDest)
                }
                try fileManager.copyItem(at: sourceURL, to: finalDest)
            }
            addToList(finalDest, mode: mode)
            return finalDest
        } catch {
            print("UserIconLibrary: failed to copy \(sourceURL.path): \(error)")
            return nil
        }
    }

    /// Remove an icon from the library
    func removeIcon(_ url: URL) {
        try? fileManager.removeItem(at: url)
        lightIcons.removeAll { $0 == url }
        darkIcons.removeAll { $0 == url }
    }

    /// Reload icons from disk
    func reload() {
        loadIcons()
    }

    private func addToList(_ url: URL, mode: AppearanceMode) {
        if mode == .light {
            if !lightIcons.contains(url) { lightIcons.append(url) }
            lightIcons.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            if !darkIcons.contains(url) { darkIcons.append(url) }
            darkIcons.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        }
    }

    private func loadIcons() {
        lightIcons = loadDir(lightDir)
        darkIcons = loadDir(darkDir)
        isReady = true
    }

    private func loadDir(_ dir: URL) -> [URL] {
        guard fileManager.fileExists(atPath: dir.path),
              let contents = try? fileManager.contentsOfDirectory(
                  at: dir,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else { return [] }

        return contents
            .filter { ["png", "jpg", "jpeg", "icns", "tiff", "tif"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }
}
