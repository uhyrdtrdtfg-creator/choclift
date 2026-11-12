import Foundation
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Cross-Platform Companion Device Identity

@MainActor
public enum CompanionDeviceIdentity {
    public struct ResolvedIdentity: Sendable {
        public let deviceID: String
        public let deviceName: String
        public let platform: DevicePlatform

        public init(deviceID: String, deviceName: String, platform: DevicePlatform) {
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.platform = platform
        }
    }

    public static func resolve(
        userDefaults: UserDefaults = .standard,
        idKey: String
    ) -> ResolvedIdentity {
        let persistedID: String = {
            if let existing = userDefaults.string(forKey: idKey), !existing.isEmpty {
                return existing
            }
            let created: String
            #if os(iOS)
            created = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            #elseif os(watchOS)
            created = WKInterfaceDevice.current().identifierForVendor?.uuidString ?? UUID().uuidString
            #else
            created = UUID().uuidString
            #endif
            userDefaults.set(created, forKey: idKey)
            return created
        }()

        #if os(iOS)
        let platform: DevicePlatform = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        let name = UIDevice.current.name
        #elseif os(watchOS)
        let platform: DevicePlatform = .appleWatch
        let rawName = WKInterfaceDevice.current().name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.isEmpty ? "Apple Watch" : rawName
        #elseif os(macOS)
        let platform: DevicePlatform = .mac
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        let platform: DevicePlatform = .iPhone
        let name = ProcessInfo.processInfo.hostName
        #endif

        return ResolvedIdentity(deviceID: persistedID, deviceName: name, platform: platform)
    }
}

// MARK: - Cross-Platform Companion Tactile Feedback

@MainActor
public enum CompanionFeedbackHaptics {
    public enum TapIntensity: Sendable {
        case light
        case medium
        case rigid
    }

    public enum NotificationKind: Sendable {
        case success
        case error
    }

    public static func tap(enabled: Bool, intensity: TapIntensity = .medium) {
        guard enabled else { return }
        #if os(iOS)
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch intensity {
        case .light: style = .light
        case .medium: style = .medium
        case .rigid: style = .rigid
        }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #elseif os(watchOS)
        switch intensity {
        case .light:
            WKInterfaceDevice.current().play(.click)
        case .medium:
            WKInterfaceDevice.current().play(.click)
        case .rigid:
            WKInterfaceDevice.current().play(.directionUp)
        }
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        #endif
    }

    public static func notify(enabled: Bool, kind: NotificationKind = .success) {
        guard enabled else { return }
        #if os(iOS)
        let feedbackType: UINotificationFeedbackGenerator.FeedbackType = (kind == .success) ? .success : .error
        UINotificationFeedbackGenerator().notificationOccurred(feedbackType)
        #elseif os(watchOS)
        WKInterfaceDevice.current().play(kind == .success ? .success : .failure)
        #endif
    }
}
