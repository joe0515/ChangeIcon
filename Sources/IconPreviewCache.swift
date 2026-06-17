import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class IconPreviewCache: ObservableObject {
    private let cache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default

    func appIcon(for appURL: URL, size: NSSize = NSSize(width: 96, height: 96)) -> NSImage {
        let key = "app:\(appURL.path):\(size.width)x\(size.height)" as NSString
        if let image = cache.object(forKey: key) {
            return image
        }

        // For uninstalled apps, skip library matching and use a generic icon
        let isInstalled = FileManager.default.fileExists(atPath: appURL.path)
        if !isInstalled {
            let placeholder = NSWorkspace.shared.icon(for: .applicationBundle)
            placeholder.size = size
            cache.setObject(placeholder, forKey: key)
            return placeholder
        }

        // Always get the current icon from NSWorkspace — this reflects the
        // app's actual current icon including any modifications made by ChangeIcon.
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        image.size = size
        cache.setObject(image, forKey: key)
        return image
    }

    /// Invalidate the cached icon for a given app so the next request
    /// re-fetches the current icon from the file system.
    func invalidateAppIcon(for appURL: URL, size: NSSize = NSSize(width: 96, height: 96)) {
        let key = "app:\(appURL.path):\(size.width)x\(size.height)" as NSString
        cache.removeObject(forKey: key)
    }

    func image(for fileURL: URL, size: NSSize = NSSize(width: 128, height: 128)) -> NSImage? {
        let modified = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "file:\(fileURL.path):\(modified):\(size.width)x\(size.height)" as NSString
        if let image = cache.object(forKey: key) {
            return image
        }

        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        image.size = size
        cache.setObject(image, forKey: key)
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
