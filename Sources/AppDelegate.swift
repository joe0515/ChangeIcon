import AppKit
import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.local.ChangeIcon", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Stored activity token to keep App Nap suppressed for the app's lifetime.
    /// Without this storage, the token is released immediately at end-of-scope
    /// and the activity protection is never actually active.
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("ChangeIcon started")

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .userInitiated],
            reason: "Monitoring system appearance changes"
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        logger.info("Termination requested")
        return .terminateNow
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        let iconURLs = urls.filter { url in
            ["icns", "png", "jpg", "jpeg", "tif", "tiff"].contains(url.pathExtension.lowercased())
        }
        guard !iconURLs.isEmpty else { return }

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
