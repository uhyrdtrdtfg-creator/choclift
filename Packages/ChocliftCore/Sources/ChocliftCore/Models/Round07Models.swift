import Foundation

// MARK: - 1. Read-Only Mac Battery & Power Adapter Status (Round 7)

/// Read-only snapshot of the Mac's battery percentage and charging state, or AC power adapter status
/// when the Mac has no internal battery (e.g. Mac mini, Mac Studio, iMac, Mac Pro).
public struct MacBatteryStatus: Codable, Equatable, Hashable, Sendable {
    public var hasBattery: Bool
    public var chargePercent: Int?
    public var isCharging: Bool
    public var isOnACPower: Bool

    private enum CodingKeys: String, CodingKey {
        case hasBattery
        case chargePercent
        case isCharging
        case isOnACPower
    }

    public init(
        hasBattery: Bool,
        chargePercent: Int?,
        isCharging: Bool,
        isOnACPower: Bool
    ) {
        self.hasBattery = hasBattery
        if hasBattery {
            let raw = chargePercent ?? 0
            self.chargePercent = min(max(0, raw), 100)
            self.isCharging = isCharging
            self.isOnACPower = isOnACPower
        } else {
            self.chargePercent = nil
            self.isCharging = false
            self.isOnACPower = true
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedHasBattery = try container.decodeIfPresent(Bool.self, forKey: .hasBattery) ?? false
        let decodedPercent = try container.decodeIfPresent(Int.self, forKey: .chargePercent)
        let decodedCharging = try container.decodeIfPresent(Bool.self, forKey: .isCharging) ?? false
        let decodedAC = try container.decodeIfPresent(Bool.self, forKey: .isOnACPower) ?? (!decodedHasBattery || decodedCharging)
        self.init(
            hasBattery: decodedHasBattery,
            chargePercent: decodedPercent,
            isCharging: decodedCharging,
            isOnACPower: decodedAC
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hasBattery, forKey: .hasBattery)
        if hasBattery, let chargePercent {
            try container.encode(min(max(0, chargePercent), 100), forKey: .chargePercent)
        }
        try container.encode(hasBattery ? isCharging : false, forKey: .isCharging)
        try container.encode(hasBattery ? isOnACPower : true, forKey: .isOnACPower)
    }

    public static func battery(
        percent: Int,
        isCharging: Bool,
        isOnACPower: Bool? = nil
    ) -> MacBatteryStatus {
        MacBatteryStatus(
            hasBattery: true,
            chargePercent: percent,
            isCharging: isCharging,
            isOnACPower: isOnACPower ?? isCharging
        )
    }

    /// Desktop Mac running on AC power with no internal battery.
    public static let powerAdapter = MacBatteryStatus(
        hasBattery: false,
        chargePercent: nil,
        isCharging: false,
        isOnACPower: true
    )

    /// Parses raw IOKit `IOPSGetPowerSourceDescription` dictionaries into a `MacBatteryStatus`.
    /// When no present `InternalBattery` entry exists, returns `.powerAdapter`.
    public static func fromPowerSourceDescriptions(_ descriptions: [[String: Any]]) -> MacBatteryStatus {
        for desc in descriptions {
            let type = (desc["Type"] as? String) ?? ""
            guard type == "InternalBattery" else { continue }
            let isPresent = (desc["Is Present"] as? Bool) ?? true
            guard isPresent else { continue }

            let current = (desc["Current Capacity"] as? Int) ?? 0
            let maxCap = (desc["Max Capacity"] as? Int) ?? 100
            let pct: Int = {
                guard maxCap > 0 else { return min(max(0, current), 100) }
                let ratio = (Double(current) / Double(maxCap)) * 100.0
                return min(max(0, Int(ratio.rounded())), 100)
            }()
            let charging = (desc["Is Charging"] as? Bool) ?? false
            let powerState = (desc["Power Source State"] as? String) ?? ""
            let onAC = (powerState == "AC Power") || charging

            return .battery(
                percent: pct,
                isCharging: charging,
                isOnACPower: onAC
            )
        }
        return .powerAdapter
    }

    /// Read-only status string rendered on the companion control strip.
    /// - Battery charging: `"82% · Charging"`
    /// - Battery not charging: `"82% · Not charging"`
    /// - AC with no battery: `"Power adapter"`
    public func displayText(in language: AppLanguage = .system) -> String {
        guard hasBattery else {
            return L10n.tr("电源适配器", "Power adapter", language: language)
        }
        let pct = min(max(0, chargePercent ?? 0), 100)
        if isCharging {
            return L10n.tr("\(pct)% · 充电中", "\(pct)% · Charging", language: language)
        } else {
            return L10n.tr("\(pct)% · 未充电", "\(pct)% · Not charging", language: language)
        }
    }

    /// SF Symbol compatible with macOS 13+, iOS 17+, and watchOS 10+.
    public var sfSymbol: String {
        guard hasBattery else {
            return "powerplug.fill"
        }
        if isCharging {
            return "battery.100.bolt"
        }
        let pct = min(max(0, chargePercent ?? 0), 100)
        switch pct {
        case ..<13:
            return "battery.0"
        case 13..<38:
            return "battery.25"
        case 38..<63:
            return "battery.50"
        case 63..<88:
            return "battery.75"
        default:
            return "battery.100"
        }
    }
}

// MARK: - 2. Finder Desktop Icons Toggle Preference & Button Copy (Round 7)

/// Pure helpers for Finder's `CreateDesktop` preference and the companion toggle button text
/// (which explicitly states on the button that Finder will restart).
public enum FinderDesktopIconsToggleCopy {
    /// Parses `com.apple.finder` `CreateDesktop` value; defaults to `true` when unset on macOS.
    public static func parseCreateDesktopValue(_ rawValue: Any?) -> Bool {
        guard let rawValue else {
            return true
        }
        if let boolVal = rawValue as? Bool {
            return boolVal
        }
        if let numberVal = rawValue as? NSNumber {
            return numberVal.boolValue
        }
        if let strVal = rawValue as? String {
            let normalized = strVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "false", "no", "0", "off":
                return false
            case "true", "yes", "1", "on":
                return true
            default:
                return true
            }
        }
        return true
    }

    public static func actionTitle(
        areIconsVisible: Bool,
        compact: Bool = false,
        language: AppLanguage = .system
    ) -> String {
        if areIconsVisible {
            return compact
                ? L10n.tr("隐藏桌面图标", "Hide Icons", language: language)
                : L10n.tr("隐藏桌面图标", "Hide Desktop Icons", language: language)
        } else {
            return compact
                ? L10n.tr("显示桌面图标", "Show Icons", language: language)
                : L10n.tr("显示桌面图标", "Show Desktop Icons", language: language)
        }
    }

    public static func restartNotice(in language: AppLanguage = .system) -> String {
        L10n.tr("Finder 将会重启", "Finder will restart", language: language)
    }

    public static func buttonCombinedLabel(
        areIconsVisible: Bool,
        compact: Bool = false,
        language: AppLanguage = .system
    ) -> String {
        "\(actionTitle(areIconsVisible: areIconsVisible, compact: compact, language: language)) · \(restartNotice(in: language))"
    }
}

// MARK: - 3. Keep-Awake Reason Formatter (Round 7)

/// Formats the explicit keep-awake reason line ONLY while Choclift's `IOPMAssertion` is active.
/// Returns `nil` when off — never invents or guesses another system wake reason.
public enum MacAwakeReasonFormatter {
    public static func reasonLine(
        isAssertionActive: Bool,
        language: AppLanguage = .system
    ) -> String? {
        guard isAssertionActive else {
            return nil
        }
        return L10n.tr(
            "Choclift 正在保持 Mac 唤醒",
            "Choclift is keeping the Mac awake",
            language: language
        )
    }
}
