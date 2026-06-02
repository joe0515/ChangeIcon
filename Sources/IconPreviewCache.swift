import AppKit
import Foundation

@MainActor
final class IconPreviewCache: ObservableObject {
    private let cache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default

    func appIcon(for appURL: URL, size: NSSize = NSSize(width: 96, height: 96)) -> NSImage {
        let key = "app:\(appURL.path):\(size.width)x\(size.height)" as NSString
        if let image = cache.object(forKey: key) {
            return image
        }

        let appName = appURL.deletingPathExtension().lastPathComponent

        if let libraryIconURL = IconLibrary.shared.findIcon(for: appName),
           let libraryImage = NSImage(contentsOf: libraryIconURL) {
            libraryImage.size = size
            cache.setObject(libraryImage, forKey: key)
            return libraryImage
        }

        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        image.size = size
        cache.setObject(image, forKey: key)
        return image
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
