import AppKit
import Foundation

@MainActor
final class AppearanceMonitor: ObservableObject {
    @Published private(set) var current: AppearanceMode = AppearanceMonitor.readCurrentMode()

    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.current = Self.readCurrentMode()
            }
        }
    }

    private static func readCurrentMode() -> AppearanceMode {
        let value = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        return value == "Dark" ? .dark : .light
    }
}
