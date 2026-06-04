import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.local.ChangeIcon", category: "Appearance")

/// Monitors macOS system appearance changes using a dual-strategy approach:
///
/// **Primary**: KVO on `NSApp.effectiveAppearance`
///   - Always fires on the main thread when the system theme changes
///   - Works regardless of app foreground/background state
///   - No notification delivery issues — this is the most reliable method
///
/// **Backup**: `CFNotificationCenterGetDistributedCenter()` with `.deliverImmediately`
///   - Receives `AppleInterfaceThemeChangedNotification` immediately
///   - Fast response when the app is frontmost
///
/// Note: `CFNotificationCenterGetDarwinNotifyCenter()` was previously used
/// but it is a SEPARATE notification system (notify_post/notify_register)
/// that does NOT receive DistributedNotificationCenter notifications.
/// `AppleInterfaceThemeChangedNotification` is only posted to the distributed
/// center, so Darwin would never receive it.
@MainActor
final class AppearanceMonitor: ObservableObject {
    @Published private(set) var current: AppearanceMode

    /// KVO observation token for NSApp.effectiveAppearance
    private var appearanceObservation: NSKeyValueObservation?

    /// Opaque context pointer for CFNotificationCenterDistributed callback.
    nonisolated(unsafe) private var distributedObserverPtr: UnsafeMutableRawPointer?

    init() {
        self.current = .light
        self.current = Self.readCurrentMode()

        logger.info("Initial appearance: \(self.current.title, privacy: .public)")

        // ── Strategy 1: KVO on NSApp.effectiveAppearance (RELIABLE) ──
        // When the system theme changes, NSApp updates its effective appearance.
        // KVO fires on the main thread — always, even in background. This is
        // the most reliable way to detect theme changes.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            // KVO on NSApp always fires on the main thread, but the compiler
            // doesn't know that. Wrap in MainActor Task to satisfy Swift 6.
            Task { @MainActor in
                let newMode = Self.readCurrentMode()
                guard newMode != self.current else { return }
                self.current = newMode
                logger.info("Appearance switched (KVO): \(newMode.title, privacy: .public)")
            }
        }

        // ── Strategy 2: DistributedNotificationCenter with deliverImmediately ──
        // This is a speed boost — it often fires slightly faster than KVO.
        // Uses the DISTRIBUTED center (not Darwin!), which is the correct
        // center for AppleInterfaceThemeChangedNotification.
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        self.distributedObserverPtr = ptr

        let center = CFNotificationCenterGetDistributedCenter()
        CFNotificationCenterAddObserver(
            center,
            ptr,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let myself = Unmanaged<AppearanceMonitor>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                // Dispatch to MainActor for the actual read+update
                Task { @MainActor in
                    let newMode = AppearanceMonitor.readCurrentMode()
                    guard newMode != myself.current else { return }
                    myself.current = newMode
                    logger.info("Appearance switched (Distributed): \(newMode.title, privacy: .public)")
                }
            },
            "AppleInterfaceThemeChangedNotification" as CFString,
            nil,
            CFNotificationSuspensionBehavior.deliverImmediately
        )
        logger.info("Appearance monitoring active (KVO + DistributedNotification)")
    }

    /// Read current system appearance using the reliable API.
    ///
    /// `NSApp.effectiveAppearance.bestMatch(from:)` is the correct approach:
    /// - Reflects the actual current appearance, not stale UserDefaults
    /// - Accounts for per-app appearance overrides
    /// - Works from Big Sur through Sonoma+
    private static func readCurrentMode() -> AppearanceMode {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .dark : .light
    }

    deinit {
        appearanceObservation?.invalidate()
        if let ptr = distributedObserverPtr {
            let center = CFNotificationCenterGetDistributedCenter()
            CFNotificationCenterRemoveEveryObserver(center, ptr)
            logger.info("AppearanceMonitor deinitialized")
        }
    }
}