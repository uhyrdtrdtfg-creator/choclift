import Foundation

public enum DeskTimerPhase: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case idle
    case running
    case paused

    public func statusLabel(in language: AppLanguage = .system) -> String {
        switch self {
        case .idle:
            return L10n.tr("待机", "Idle", language: language)
        case .running:
            return L10n.tr("计时中", "Running", language: language)
        case .paused:
            return L10n.tr("已暂停", "Paused", language: language)
        }
    }
}

public struct DeskTimerState: Codable, Equatable, Hashable, Sendable {
    public static let presetMinutes: [Int] = [5, 10, 15, 25, 45]
    public static let defaultPresetSeconds: Int = 25 * 60
    public static let maxPresetSeconds: Int = 24 * 60 * 60

    public static let idle = DeskTimerState()

    public var phase: DeskTimerPhase
    public var presetSeconds: Int
    public var remainingSeconds: Int
    public var endsAt: Date?

    private enum CodingKeys: String, CodingKey {
        case phase
        case presetSeconds
        case remainingSeconds
        case endsAt
    }

    public init(
        phase: DeskTimerPhase = .idle,
        presetSeconds: Int = DeskTimerState.defaultPresetSeconds,
        remainingSeconds: Int? = nil,
        endsAt: Date? = nil
    ) {
        let clampedPreset = min(max(0, presetSeconds), Self.maxPresetSeconds)
        self.phase = phase
        self.presetSeconds = clampedPreset
        let defaultRemaining = (phase == .idle) ? clampedPreset : 0
        self.remainingSeconds = min(max(0, remainingSeconds ?? defaultRemaining), Self.maxPresetSeconds)
        self.endsAt = (phase == .running) ? endsAt : nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPhase = try container.decodeIfPresent(DeskTimerPhase.self, forKey: .phase) ?? .idle
        let rawPreset = try container.decodeIfPresent(Int.self, forKey: .presetSeconds)
        let resolvedPreset: Int
        if let rawPreset, rawPreset > 0 {
            resolvedPreset = min(rawPreset, Self.maxPresetSeconds)
        } else {
            resolvedPreset = Self.defaultPresetSeconds
        }
        let defaultRemaining = (decodedPhase == .idle) ? resolvedPreset : 0
        let rawRemaining = try container.decodeIfPresent(Int.self, forKey: .remainingSeconds) ?? defaultRemaining
        let clampedRemaining = min(max(0, rawRemaining), Self.maxPresetSeconds)
        let decodedEndsAt = try container.decodeIfPresent(Date.self, forKey: .endsAt)

        if decodedPhase == .running, let endsAt = decodedEndsAt {
            self.phase = .running
            self.presetSeconds = resolvedPreset
            self.remainingSeconds = clampedRemaining
            self.endsAt = endsAt
        } else if decodedPhase == .running {
            self.phase = .idle
            self.presetSeconds = resolvedPreset
            self.remainingSeconds = resolvedPreset
            self.endsAt = nil
        } else {
            self.phase = decodedPhase
            self.presetSeconds = resolvedPreset
            self.remainingSeconds = clampedRemaining
            self.endsAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phase, forKey: .phase)
        try container.encode(presetSeconds, forKey: .presetSeconds)
        try container.encode(remainingSeconds, forKey: .remainingSeconds)
        try container.encodeIfPresent(endsAt, forKey: .endsAt)
    }

    public func remaining(at now: Date = Date()) -> Int {
        switch phase {
        case .running:
            guard let endsAt else {
                return max(0, remainingSeconds)
            }
            let delta = endsAt.timeIntervalSince(now)
            guard delta > 1e-6 else { return 0 }
            return max(0, Int((delta - 1e-6).rounded(.up)))
        case .paused:
            return max(0, remainingSeconds)
        case .idle:
            return max(0, presetSeconds)
        }
    }

    public static func started(preset: Int, now: Date = Date()) -> DeskTimerState {
        let resolvedPreset = sanitizePreset(preset)
        return DeskTimerState(
            phase: .running,
            presetSeconds: resolvedPreset,
            remainingSeconds: resolvedPreset,
            endsAt: now.addingTimeInterval(TimeInterval(resolvedPreset))
        )
    }

    public func paused(at now: Date = Date()) -> DeskTimerState {
        guard phase == .running else { return self }
        let left = remaining(at: now)
        guard left > 0 else {
            return reset()
        }
        return DeskTimerState(
            phase: .paused,
            presetSeconds: Self.sanitizePreset(presetSeconds),
            remainingSeconds: left,
            endsAt: nil
        )
    }

    public func resumed(at now: Date = Date()) -> DeskTimerState {
        guard phase == .paused else { return self }
        let left = max(0, remainingSeconds)
        guard left > 0 else {
            return reset()
        }
        return DeskTimerState(
            phase: .running,
            presetSeconds: Self.sanitizePreset(presetSeconds),
            remainingSeconds: left,
            endsAt: now.addingTimeInterval(TimeInterval(left))
        )
    }

    public func reset() -> DeskTimerState {
        let resolvedPreset = Self.sanitizePreset(presetSeconds)
        return DeskTimerState(
            phase: .idle,
            presetSeconds: resolvedPreset,
            remainingSeconds: resolvedPreset,
            endsAt: nil
        )
    }

    public static func formattedClock(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let minutes = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    public func formattedRemaining(at now: Date = Date()) -> String {
        Self.formattedClock(seconds: remaining(at: now))
    }

    public static func cardTitle(in language: AppLanguage = .system) -> String {
        L10n.tr("计时器", "Timer", language: language)
    }

    public static func presetChipTitle(minutes: Int, in language: AppLanguage = .system) -> String {
        L10n.tr("\(minutes)分", "\(minutes)m", language: language)
    }

    private static func sanitizePreset(_ rawSeconds: Int) -> Int {
        guard rawSeconds > 0 else { return defaultPresetSeconds }
        return min(rawSeconds, maxPresetSeconds)
    }
}
