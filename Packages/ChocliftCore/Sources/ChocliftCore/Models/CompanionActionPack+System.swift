import Foundation

public enum SystemSettingsAction: String, CaseIterable, Equatable, Hashable, Sendable {
    case openSettings = "system.open_settings"
    case openBluetoothSettings = "system.open_bluetooth_settings"
    case openSoundSettings = "system.open_sound_settings"
    case openDisplaySettings = "system.open_display_settings"
    case openNetworkSettings = "system.open_network_settings"
    case openNotificationsSettings = "system.open_notifications_settings"
    case openFocusSettings = "system.open_focus_settings"
    case openKeyboardSettings = "system.open_keyboard_settings"
    case openTrackpadSettings = "system.open_trackpad_settings"
    case openBatterySettings = "system.open_battery_settings"

    public var constantURL: StaticString {
        switch self {
        case .openSettings:
            return "x-apple.systempreferences:"
        case .openBluetoothSettings:
            return "x-apple.systempreferences:com.apple.BluetoothSettings"
        case .openSoundSettings:
            return "x-apple.systempreferences:com.apple.preference.sound"
        case .openDisplaySettings:
            return "x-apple.systempreferences:com.apple.preference.displays"
        case .openNetworkSettings:
            return "x-apple.systempreferences:com.apple.preference.network"
        case .openNotificationsSettings:
            return "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .openFocusSettings:
            return "x-apple.systempreferences:com.apple.Focus-Settings.extension"
        case .openKeyboardSettings:
            return "x-apple.systempreferences:com.apple.preference.keyboard"
        case .openTrackpadSettings:
            return "x-apple.systempreferences:com.apple.preference.trackpad"
        case .openBatterySettings:
            return "x-apple.systempreferences:com.apple.preference.battery"
        }
    }

    public var urlString: String {
        constantURL.description
    }

    public var destinationURL: URL? {
        URL(string: urlString)
    }

    public var sfSymbol: String {
        switch self {
        case .openSettings:
            return "gearshape.fill"
        case .openBluetoothSettings:
            return "dot.radiowaves.left.and.right"
        case .openSoundSettings:
            return "speaker.wave.2.fill"
        case .openDisplaySettings:
            return "display"
        case .openNetworkSettings:
            return "network"
        case .openNotificationsSettings:
            return "bell.badge.fill"
        case .openFocusSettings:
            return "moon.fill"
        case .openKeyboardSettings:
            return "keyboard.fill"
        case .openTrackpadSettings:
            return "hand.tap.fill"
        case .openBatterySettings:
            return "battery.100"
        }
    }

    private var paneNameZh: String {
        switch self {
        case .openSettings:
            return "系统设置"
        case .openBluetoothSettings:
            return "蓝牙设置"
        case .openSoundSettings:
            return "声音设置"
        case .openDisplaySettings:
            return "显示器设置"
        case .openNetworkSettings:
            return "网络设置"
        case .openNotificationsSettings:
            return "通知设置"
        case .openFocusSettings:
            return "专注模式设置"
        case .openKeyboardSettings:
            return "键盘设置"
        case .openTrackpadSettings:
            return "触控板设置"
        case .openBatterySettings:
            return "电池设置"
        }
    }

    private var paneNameEn: String {
        switch self {
        case .openSettings:
            return "System Settings"
        case .openBluetoothSettings:
            return "Bluetooth Settings"
        case .openSoundSettings:
            return "Sound Settings"
        case .openDisplaySettings:
            return "Display Settings"
        case .openNetworkSettings:
            return "Network Settings"
        case .openNotificationsSettings:
            return "Notifications Settings"
        case .openFocusSettings:
            return "Focus Settings"
        case .openKeyboardSettings:
            return "Keyboard Settings"
        case .openTrackpadSettings:
            return "Trackpad Settings"
        case .openBatterySettings:
            return "Battery Settings"
        }
    }

    public var companionAction: CompanionAction {
        CompanionAction(
            id: rawValue,
            titleZh: "打开\(paneNameZh)",
            titleEn: "Open \(paneNameEn)",
            sfSymbol: sfSymbol
        )
    }

    public func openedMessage(in language: AppLanguage = .system) -> String {
        L10n.tr("已打开\(paneNameZh)", "Opened \(paneNameEn)", language: language)
    }

    public func failureMessage(in language: AppLanguage = .system) -> String {
        L10n.tr("无法打开\(paneNameZh)", "Could not open \(paneNameEn)", language: language)
    }

    public static let urlTable: [String: String] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.urlString) }
    )

    public static func urlString(for id: String) -> String? {
        urlTable[id]
    }

    public static func destinationURL(for id: String) -> URL? {
        guard let rawURL = urlTable[id] else { return nil }
        return URL(string: rawURL)
    }

    public static func execute(
        id: String,
        language: AppLanguage = .system,
        openURL: (URL) -> Bool
    ) -> (success: Bool, message: String) {
        guard let action = SystemSettingsAction(rawValue: id) else {
            return (
                false,
                L10n.tr("不支持的系统设置操作", "Unsupported system settings action", language: language)
            )
        }
        guard let url = action.destinationURL, openURL(url) else {
            return (false, action.failureMessage(in: language))
        }
        return (true, action.openedMessage(in: language))
    }
}

extension CompanionActionCatalog {
    public static let systemPack: [CompanionAction] = SystemSettingsAction.allCases.map(\.companionAction)
    public static let systemSettingsURLByID: [String: String] = SystemSettingsAction.urlTable

    public static func systemSettingsURLString(for id: String) -> String? {
        SystemSettingsAction.urlTable[id]
    }
}
