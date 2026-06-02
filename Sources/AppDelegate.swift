import AppKit
import SwiftUI

/// Handles Dock tile drag-and-drop for quick icon replacement.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nothing special needed on launch
    }

    /// Accept file drops on the Dock tile
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        let iconURLs = urls.filter { url in
            ["icns", "png", "jpg", "jpeg", "tif", "tiff"].contains(url.pathExtension.lowercased())
        }

        guard !iconURLs.isEmpty else { return }

        // Post notification so ContentView can handle it
        NotificationCenter.default.post(
            name: .dockIconDropped,
            object: nil,
            userInfo: ["urls": iconURLs]
        )

        NSApp.reply(toOpenOrPrint: .success)
    }
}

extension Notification.Name {
    static let dockIconDropped = Notification.Name("ChangeIcon.dockIconDropped")
}
