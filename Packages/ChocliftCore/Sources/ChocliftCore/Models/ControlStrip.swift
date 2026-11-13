import Foundation

// MARK: - Control Strip Level Kind & Clamping

public enum ControlLevelKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case volume
    case brightness

    public var id: String { rawValue }
}

public enum ControlStripLevel {
    /// Clamps any raw floating-point level to `0.0...1.0` (`NaN` maps safely to `0.0`).
    public static func clamp(_ rawValue: Double) -> Double {
        guard !rawValue.isNaN else { return 0.0 }
        return min(1.0, max(0.0, rawValue))
    }

    /// Rounded integer percentage (`0...100`) for display.
    public static func percentage(for level: Double) -> Int {
        Int((clamp(level) * 100.0).rounded())
    }
}

// MARK: - Pure Drag Throttle (<= 1 update / 150 ms during drag + guaranteed final level on end)

public struct ControlLevelDragThrottle: Equatable, Sendable {
    public static let defaultMinimumInterval: TimeInterval = 0.15

    public let minimumInterval: TimeInterval
    public private(set) var isDragging: Bool = false
    public private(set) var lastSentTimestamp: TimeInterval?
    public private(set) var lastSentLevel: Double?
    public private(set) var latestDragLevel: Double?

    public init(minimumInterval: TimeInterval = ControlLevelDragThrottle.defaultMinimumInterval) {
        self.minimumInterval = max(0.0, minimumInterval)
    }

    /// Records an in-progress drag update and returns the clamped level to send if at least
    /// `minimumInterval` (150 ms by default) has elapsed since the previous sent update.
    public mutating func updateDrag(to rawLevel: Double, at timestamp: TimeInterval) -> Double? {
        let clamped = ControlStripLevel.clamp(rawLevel)
        isDragging = true
        latestDragLevel = clamped

        if let lastSent = lastSentTimestamp {
            let elapsed = timestamp - lastSent
            if elapsed + 1e-9 < minimumInterval {
                return nil
            }
        }

        lastSentTimestamp = timestamp
        lastSentLevel = clamped
        return clamped
    }

    /// Ends the current drag and unconditionally returns the final clamped level so the Mac
    /// always converges to the exact release position.
    public mutating func endDrag(at rawLevel: Double, at timestamp: TimeInterval) -> Double {
        let clamped = ControlStripLevel.clamp(rawLevel)
        isDragging = false
        latestDragLevel = nil
        lastSentTimestamp = timestamp
        lastSentLevel = clamped
        return clamped
    }

    public mutating func reset() {
        isDragging = false
        latestDragLevel = nil
        lastSentTimestamp = nil
        lastSentLevel = nil
    }
}

// MARK: - Now Playing & Control Strip Snapshot

public struct NowPlayingStatus: Codable, Equatable, Hashable, Sendable {
    public var title: String?
    public var artist: String?
    public var appName: String?
    public var isPlaying: Bool

    private enum CodingKeys: String, CodingKey {
        case title
        case artist
        case appName
        case isPlaying
    }

    public init(
        title: String? = nil,
        artist: String? = nil,
        appName: String? = nil,
        isPlaying: Bool = false
    ) {
        self.title = Self.clean(title)
        self.artist = Self.clean(artist)
        self.appName = Self.clean(appName)
        self.isPlaying = isPlaying
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = Self.clean(try container.decodeIfPresent(String.self, forKey: .title))
        self.artist = Self.clean(try container.decodeIfPresent(String.self, forKey: .artist))
        self.appName = Self.clean(try container.decodeIfPresent(String.self, forKey: .appName))
        self.isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(artist, forKey: .artist)
        try container.encodeIfPresent(appName, forKey: .appName)
        try container.encode(isPlaying, forKey: .isPlaying)
    }

    /// Track title if available, otherwise the active media app name.
    public var primaryDisplayText: String? {
        if let title, !title.isEmpty {
            return title
        }
        if let appName, !appName.isEmpty {
            return appName
        }
        return nil
    }

    /// Artist or app name subtitle when a distinct track title is displayed.
    public var secondaryDisplayText: String? {
        guard let title, !title.isEmpty else { return nil }
        if let artist, !artist.isEmpty {
            return artist
        }
        if let appName, !appName.isEmpty, appName != title {
            return appName
        }
        return nil
    }

    public var hasActiveMedia: Bool {
        primaryDisplayText != nil
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public struct ControlStripState: Codable, Equatable, Hashable, Sendable {
    public var volume: Double
    public var isVolumeMuted: Bool
    public var brightness: Double
    public var isBrightnessAvailable: Bool
    public var isMicMuted: Bool
    public var nowPlaying: NowPlayingStatus?

    private enum CodingKeys: String, CodingKey {
        case volume
        case isVolumeMuted
        case brightness
        case isBrightnessAvailable
        case isMicMuted
        case nowPlaying
    }

    public init(
        volume: Double = 0.5,
        isVolumeMuted: Bool = false,
        brightness: Double = 0.75,
        isBrightnessAvailable: Bool = true,
        isMicMuted: Bool = false,
        nowPlaying: NowPlayingStatus? = nil
    ) {
        self.volume = ControlStripLevel.clamp(volume)
        self.isVolumeMuted = isVolumeMuted
        self.brightness = ControlStripLevel.clamp(brightness)
        self.isBrightnessAvailable = isBrightnessAvailable
        self.isMicMuted = isMicMuted
        self.nowPlaying = (nowPlaying?.hasActiveMedia == true) ? nowPlaying : nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVolume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.5
        let decodedBrightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0.75
        self.volume = ControlStripLevel.clamp(decodedVolume)
        self.isVolumeMuted = try container.decodeIfPresent(Bool.self, forKey: .isVolumeMuted) ?? false
        self.brightness = ControlStripLevel.clamp(decodedBrightness)
        self.isBrightnessAvailable = try container.decodeIfPresent(Bool.self, forKey: .isBrightnessAvailable) ?? true
        self.isMicMuted = try container.decodeIfPresent(Bool.self, forKey: .isMicMuted) ?? false
        let decodedNP = try container.decodeIfPresent(NowPlayingStatus.self, forKey: .nowPlaying)
        self.nowPlaying = (decodedNP?.hasActiveMedia == true) ? decodedNP : nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ControlStripLevel.clamp(volume), forKey: .volume)
        try container.encode(isVolumeMuted, forKey: .isVolumeMuted)
        try container.encode(ControlStripLevel.clamp(brightness), forKey: .brightness)
        try container.encode(isBrightnessAvailable, forKey: .isBrightnessAvailable)
        try container.encode(isMicMuted, forKey: .isMicMuted)
        try container.encodeIfPresent(nowPlaying, forKey: .nowPlaying)
    }

    public func hasMeaningfulDifference(from other: ControlStripState, tolerance: Double = 0.004) -> Bool {
        if isVolumeMuted != other.isVolumeMuted ||
            isBrightnessAvailable != other.isBrightnessAvailable ||
            isMicMuted != other.isMicMuted ||
            nowPlaying != other.nowPlaying {
            return true
        }
        if (volume <= 0.001) != (other.volume <= 0.001) ||
            (volume >= 0.999) != (other.volume >= 0.999) ||
            (brightness <= 0.001) != (other.brightness <= 0.001) ||
            (brightness >= 0.999) != (other.brightness >= 0.999) {
            return true
        }
        return abs(volume - other.volume) >= tolerance ||
            abs(brightness - other.brightness) >= tolerance
    }
}
