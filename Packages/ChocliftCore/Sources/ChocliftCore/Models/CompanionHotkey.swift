import Foundation

public struct CompanionHotkey: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var keyCode: UInt16          // CGKeyCode / kVK_*
    public var carbonModifiers: UInt32  // Carbon cmdKey | shiftKey | optionKey | controlKey
    public var actionID: String         // SystemQuickAction.rawValue or CompanionAction.id
    public var title: String

    public init(
        id: UUID = UUID(),
        keyCode: UInt16,
        carbonModifiers: UInt32,
        actionID: String,
        title: String
    ) {
        self.id = id
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.actionID = actionID
        self.title = title
    }

    public var displayLabel: String {
        CompanionHotkeyLibrary.displayLabel(keyCode: keyCode, carbonModifiers: carbonModifiers)
    }

    public func resolvedTitle(in language: AppLanguage = .system) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return CompanionHotkeyLibrary.actionTitle(for: actionID, in: language) ?? actionID
    }
}

public enum CompanionHotkeyModifiers {
    public static let command: UInt32 = 1 << 8   // Carbon cmdKey (0x0100)
    public static let shift: UInt32 = 1 << 9     // Carbon shiftKey (0x0200)
    public static let option: UInt32 = 1 << 11   // Carbon optionKey (0x0800)
    public static let control: UInt32 = 1 << 12  // Carbon controlKey (0x1000)

    public static let allowedMask: UInt32 = command | shift | option | control
    public static let requiredNonShiftMask: UInt32 = command | option | control

    public static func make(
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shift: Bool = false
    ) -> UInt32 {
        var bits: UInt32 = 0
        if command { bits |= Self.command }
        if option { bits |= Self.option }
        if control { bits |= Self.control }
        if shift { bits |= Self.shift }
        return bits
    }
}

public struct CompanionHotkeyKeyOption: Identifiable, Equatable, Hashable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case letters
        case numbers
        case arrows
        case special

        public func title(in language: AppLanguage = .system) -> String {
            switch self {
            case .letters: return L10n.tr("字母", "Letters", language: language)
            case .numbers: return L10n.tr("数字", "Numbers", language: language)
            case .arrows: return L10n.tr("方向键", "Arrows", language: language)
            case .special: return L10n.tr("常用键", "Special", language: language)
            }
        }
    }

    public let keyCode: UInt16
    public let label: String
    public let category: Category

    public var id: UInt16 { keyCode }

    public init(keyCode: UInt16, label: String, category: Category) {
        self.keyCode = keyCode
        self.label = label
        self.category = category
    }
}

public struct CompanionHotkeyActionOption: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let sfSymbol: String
    public let isSystemQuickAction: Bool

    public init(id: String, sfSymbol: String, isSystemQuickAction: Bool) {
        self.id = id
        self.sfSymbol = sfSymbol
        self.isSystemQuickAction = isSystemQuickAction
    }

    public func title(in language: AppLanguage = .system) -> String {
        CompanionHotkeyLibrary.actionTitle(for: id, in: language) ?? id
    }
}

public enum CompanionHotkeyLibrary {
    public static let maxCount = 8

    private struct ChordKey: Hashable {
        let keyCode: UInt16
        let carbonModifiers: UInt32
    }

    public static let knownActionIDs: Set<String> = {
        var ids = Set(SystemQuickAction.allCases.map(\.rawValue))
        for action in CompanionActionCatalog.all {
            ids.insert(action.id)
        }
        return ids
    }()

    public static let allActionOptions: [CompanionHotkeyActionOption] = {
        let quick = SystemQuickAction.allCases.map {
            CompanionHotkeyActionOption(id: $0.rawValue, sfSymbol: $0.sfSymbol, isSystemQuickAction: true)
        }
        let companion = CompanionActionCatalog.all.map {
            CompanionHotkeyActionOption(id: $0.id, sfSymbol: $0.sfSymbol, isSystemQuickAction: false)
        }
        return quick + companion
    }()

    public static func isKnownActionID(_ id: String) -> Bool {
        knownActionIDs.contains(id.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func isQuitStyleAction(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespacesAndNewlines) == SystemQuickAction.quitApp.rawValue
    }

    public static func actionTitle(for id: String, in language: AppLanguage = .system) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let quick = SystemQuickAction(rawValue: trimmed) {
            return quick.title(in: language)
        }
        if let companion = CompanionActionCatalog.action(id: trimmed) {
            return companion.title(in: language)
        }
        return nil
    }

    public static func actionSymbol(for id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let quick = SystemQuickAction(rawValue: trimmed) {
            return quick.sfSymbol
        }
        if let companion = CompanionActionCatalog.action(id: trimmed) {
            return companion.sfSymbol
        }
        return "command"
    }

    public static func normalizedModifiers(_ carbonModifiers: UInt32) -> UInt32 {
        carbonModifiers & CompanionHotkeyModifiers.allowedMask
    }

    /// Requires at least one of Command, Option, or Control; refuses no-modifier and Shift-only chords.
    public static func hasRequiredModifiers(_ carbonModifiers: UInt32) -> Bool {
        let masked = normalizedModifiers(carbonModifiers)
        return (masked & CompanionHotkeyModifiers.requiredNonShiftMask) != 0
    }

    public static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        (0x36...0x3F).contains(keyCode)
    }

    public static func sanitize(_ hotkeys: [CompanionHotkey]) -> [CompanionHotkey] {
        var result: [CompanionHotkey] = []
        var seenChords = Set<ChordKey>()

        for item in hotkeys {
            guard result.count < maxCount else { break }
            let trimmedActionID = item.actionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard knownActionIDs.contains(trimmedActionID) else { continue }
            guard item.keyCode != 0 else { continue }

            let maskedModifiers = normalizedModifiers(item.carbonModifiers)
            guard hasRequiredModifiers(maskedModifiers) else { continue }

            let chord = ChordKey(keyCode: item.keyCode, carbonModifiers: maskedModifiers)
            guard seenChords.insert(chord).inserted else { continue }

            result.append(
                CompanionHotkey(
                    id: item.id,
                    keyCode: item.keyCode,
                    carbonModifiers: maskedModifiers,
                    actionID: trimmedActionID,
                    title: item.title
                )
            )
        }

        return result
    }

    public static func displayLabel(keyCode: UInt16, carbonModifiers: UInt32) -> String {
        let masked = normalizedModifiers(carbonModifiers)
        var prefix = ""
        if (masked & CompanionHotkeyModifiers.control) != 0 { prefix += "⌃" }
        if (masked & CompanionHotkeyModifiers.option) != 0 { prefix += "⌥" }
        if (masked & CompanionHotkeyModifiers.shift) != 0 { prefix += "⇧" }
        if (masked & CompanionHotkeyModifiers.command) != 0 { prefix += "⌘" }
        return prefix + keyName(for: keyCode)
    }

    /// Key options for iOS picker (all non-zero Carbon virtual key codes).
    public static let pickerKeyOptions: [CompanionHotkeyKeyOption] = [
        // Letters (B-Z; Carbon kVK_ANSI_A is 0x00 and omitted because keyCode 0 is invalid)
        CompanionHotkeyKeyOption(keyCode: 0x0B, label: "B", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x08, label: "C", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x02, label: "D", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x0E, label: "E", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x03, label: "F", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x05, label: "G", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x04, label: "H", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x22, label: "I", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x26, label: "J", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x28, label: "K", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x25, label: "L", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x2E, label: "M", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x2D, label: "N", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x1F, label: "O", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x23, label: "P", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x0C, label: "Q", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x0F, label: "R", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x01, label: "S", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x11, label: "T", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x20, label: "U", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x09, label: "V", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x0D, label: "W", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x07, label: "X", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x10, label: "Y", category: .letters),
        CompanionHotkeyKeyOption(keyCode: 0x06, label: "Z", category: .letters),
        // Numbers
        CompanionHotkeyKeyOption(keyCode: 0x1D, label: "0", category: .numbers),
        CompanionHotkeyKeyOption(keyCode: 0x12, label: "1", category: .numbers),
        CompanionHotkeyKeyOption(keyCode: 0x13, label: "2", category: .numbers),
        CompanionHotkeyKeyOption(keyCode: 0x14, label: "3", category: .numbers),
        CompanionHotkeyKeyOption(keyCode: 0x15, label: "4", category: .numbers),
        CompanionHotkeyKeyOption(keyCode: 0x17, label: "5", category: .numbers),
        CompanionHotkeyKeyOption(keyCode: 0x16, label: "6", category: .numbers),
        CompanionHotkeyKeyOption(keyCode: 0x1A, label: "7", category: .numbers),
        CompanionHotkeyKeyOption(keyCode: 0x1C, label: "8", category: .numbers),
        CompanionHotkeyKeyOption(keyCode: 0x19, label: "9", category: .numbers),
        // Arrows
        CompanionHotkeyKeyOption(keyCode: 0x7B, label: "←", category: .arrows),
        CompanionHotkeyKeyOption(keyCode: 0x7C, label: "→", category: .arrows),
        CompanionHotkeyKeyOption(keyCode: 0x7E, label: "↑", category: .arrows),
        CompanionHotkeyKeyOption(keyCode: 0x7D, label: "↓", category: .arrows),
        // Special
        CompanionHotkeyKeyOption(keyCode: 0x31, label: "Space", category: .special),
        CompanionHotkeyKeyOption(keyCode: 0x24, label: "Return", category: .special),
        CompanionHotkeyKeyOption(keyCode: 0x30, label: "Tab", category: .special)
    ]

    public static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0x00: return "A"
        case 0x01: return "S"
        case 0x02: return "D"
        case 0x03: return "F"
        case 0x04: return "H"
        case 0x05: return "G"
        case 0x06: return "Z"
        case 0x07: return "X"
        case 0x08: return "C"
        case 0x09: return "V"
        case 0x0B: return "B"
        case 0x0C: return "Q"
        case 0x0D: return "W"
        case 0x0E: return "E"
        case 0x0F: return "R"
        case 0x10: return "Y"
        case 0x11: return "T"
        case 0x12: return "1"
        case 0x13: return "2"
        case 0x14: return "3"
        case 0x15: return "4"
        case 0x16: return "6"
        case 0x17: return "5"
        case 0x18: return "="
        case 0x19: return "9"
        case 0x1A: return "7"
        case 0x1B: return "-"
        case 0x1C: return "8"
        case 0x1D: return "0"
        case 0x1E: return "]"
        case 0x1F: return "O"
        case 0x20: return "U"
        case 0x21: return "["
        case 0x22: return "I"
        case 0x23: return "P"
        case 0x24: return "Return"
        case 0x25: return "L"
        case 0x26: return "J"
        case 0x27: return "'"
        case 0x28: return "K"
        case 0x29: return ";"
        case 0x2A: return "\\"
        case 0x2B: return ","
        case 0x2C: return "/"
        case 0x2D: return "N"
        case 0x2E: return "M"
        case 0x2F: return "."
        case 0x30: return "Tab"
        case 0x31: return "Space"
        case 0x32: return "`"
        case 0x33: return "⌫"
        case 0x35: return "⎋"
        case 0x40: return "F17"
        case 0x4F: return "F18"
        case 0x50: return "F19"
        case 0x5A: return "F20"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x63: return "F3"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x67: return "F11"
        case 0x69: return "F13"
        case 0x6A: return "F16"
        case 0x6B: return "F14"
        case 0x6D: return "F10"
        case 0x6F: return "F12"
        case 0x71: return "F15"
        case 0x73: return "Home"
        case 0x74: return "PgUp"
        case 0x75: return "⌦"
        case 0x76: return "F4"
        case 0x77: return "End"
        case 0x78: return "F2"
        case 0x79: return "PgDn"
        case 0x7A: return "F1"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        default: return "Key\(keyCode)"
        }
    }
}
