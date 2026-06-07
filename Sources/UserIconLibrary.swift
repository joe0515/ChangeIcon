import AppKit
import Foundation
import OSLog

@MainActor
final class UserIconLibrary: ObservableObject {
    static let shared = UserIconLibrary()

    @Published private(set) var lightIcons: [URL] = []
    @Published private(set) var darkIcons: [URL] = []
    @Published private(set) var isReady = false

    private let fileManager = FileManager.default
    private let lightDir: URL
    private let darkDir: URL
    private let logger = Logger(subsystem: "com.changeicon.app", category: "UserIconLibrary")

    /// Maps icon filename → set of app bundle identifiers that the icon is associated with.
    /// Icons without any association are considered "global" and visible to all apps (legacy).
    private var appAssociations: [String: Set<String>] = [:]
    private let metadataURL: URL

    private init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let baseDir = support.appendingPathComponent("ChangeIcon/UserIcons", isDirectory: true)
        lightDir = baseDir.appendingPathComponent("Light", isDirectory: true)
        darkDir = baseDir.appendingPathComponent("Dark", isDirectory: true)
        metadataURL = baseDir.appendingPathComponent("associations.json")

        try? fileManager.createDirectory(at: lightDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: darkDir, withIntermediateDirectories: true)

        loadAssociations()
        loadIcons()
    }

    // MARK: - Public API

    /// Copy an icon to the library, optionally associating it with a specific app.
    func addIcon(from sourceURL: URL, mode: AppearanceMode, appIdentifier: String? = nil) -> URL? {
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
            if let appID = appIdentifier {
                associateIcon(dest, with: appID)
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

            if let appID = appIdentifier {
                associateIcon(finalDest, with: appID)
            }

            return finalDest
        } catch {
            logger.error("Failed to copy \(sourceURL.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Remove an icon from the library
    func removeIcon(_ url: URL) {
        try? fileManager.removeItem(at: url)
        lightIcons.removeAll { $0 == url }
        darkIcons.removeAll { $0 == url }
        // Also clean up association
        let key = url.lastPathComponent
        appAssociations.removeValue(forKey: key)
        saveAssociations()
    }

    /// Associate an existing icon with an app. Useful for icons imported before this feature existed.
    func associateIcon(_ iconURL: URL, with appIdentifier: String) {
        let key = iconURL.lastPathComponent
        var apps = appAssociations[key] ?? []
        apps.insert(appIdentifier)
        appAssociations[key] = apps
        saveAssociations()
    }

    /// Get icons filtered by app for a given mode.
    /// - Icons that have NO associations (legacy) are visible to all apps.
    /// - Icons with associations are only visible to matching apps.
    func filteredIcons(mode: AppearanceMode, for appIdentifier: String?) -> [URL] {
        let allIcons = mode == .light ? lightIcons : darkIcons

        guard let appID = appIdentifier else {
            // No app selected — show all icons
            return allIcons
        }

        return allIcons.filter { iconURL in
            let key = iconURL.lastPathComponent
            guard let apps = appAssociations[key] else {
                // No association — legacy icon, visible to all
                return true
            }
            return apps.contains(appID)
        }
    }

    /// Reload icons from disk
    func reload() {
        loadAssociations()
        loadIcons()
    }

    // MARK: - Private

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

        // Clean up associations for icons that no longer exist
        let existingNames = Set(
            (lightIcons + darkIcons).map { $0.lastPathComponent }
        )
        let removedKeys = appAssociations.keys.filter { !existingNames.contains($0) }
        if !removedKeys.isEmpty {
            for key in removedKeys { appAssociations.removeValue(forKey: key) }
            saveAssociations()
        }

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

    // MARK: - Association Persistence

    private func loadAssociations() {
        guard fileManager.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else {
            appAssociations = [:]
            return
        }
        // Convert arrays to Sets
        appAssociations = decoded.mapValues { Set($0) }
    }

    private func saveAssociations() {
        // Convert Sets to arrays for JSON encoding
        let encodable = appAssociations.mapValues { Array($0) }
        do {
            let data = try JSONEncoder().encode(encodable)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            logger.error("Failed to save associations: \(error.localizedDescription)")
        }
    }
}
