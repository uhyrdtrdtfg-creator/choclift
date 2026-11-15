import Foundation

public enum MediaCompanionSeekKind: Equatable, Hashable, Sendable {
    case relative(deltaSeconds: Double)
    case restartTrack
}

public struct MediaCompanionSeekSession: Equatable, Sendable {
    public var positionSeconds: Double?
    public var durationSeconds: Double?

    public init(positionSeconds: Double? = nil, durationSeconds: Double? = nil) {
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
    }
}

public struct MediaCompanionRepeatSession: Equatable, Sendable {
    public var target: MacMediaPlaybackModeTargetPlayer?
    public var currentRepeat: NowPlayingRepeatMode?
    public var failureMessage: String?

    public init(
        target: MacMediaPlaybackModeTargetPlayer? = nil,
        currentRepeat: NowPlayingRepeatMode? = nil,
        failureMessage: String? = nil
    ) {
        self.target = target
        self.currentRepeat = currentRepeat
        self.failureMessage = failureMessage
    }
}

public enum MediaCompanionAction: String, CaseIterable, Equatable, Hashable, Sendable {
    case seekBack30 = "media.seek_back_30"
    case seekForward30 = "media.seek_forward_30"
    case seekBack60 = "media.seek_back_60"
    case seekForward60 = "media.seek_forward_60"
    case restartTrack = "media.restart_track"
    case volume25 = "media.volume_25"
    case volume50 = "media.volume_50"
    case volume75 = "media.volume_75"
    case volume100 = "media.volume_100"
    case toggleRepeat = "media.toggle_repeat"

    public static let repeatCycleOrder: [NowPlayingRepeatMode] = [.off, .one, .all]

    public var companionAction: CompanionAction {
        switch self {
        case .seekBack30:
            return CompanionAction(id: rawValue, titleZh: "快退 30 秒", titleEn: "Back 30s", sfSymbol: "gobackward.30")
        case .seekForward30:
            return CompanionAction(id: rawValue, titleZh: "快进 30 秒", titleEn: "Forward 30s", sfSymbol: "goforward.30")
        case .seekBack60:
            return CompanionAction(id: rawValue, titleZh: "快退 60 秒", titleEn: "Back 60s", sfSymbol: "gobackward.60")
        case .seekForward60:
            return CompanionAction(id: rawValue, titleZh: "快进 60 秒", titleEn: "Forward 60s", sfSymbol: "goforward.60")
        case .restartTrack:
            return CompanionAction(id: rawValue, titleZh: "重播当前曲目", titleEn: "Restart Track", sfSymbol: "backward.end.fill")
        case .volume25:
            return CompanionAction(id: rawValue, titleZh: "音量 25%", titleEn: "Volume 25%", sfSymbol: "speaker.wave.1.fill")
        case .volume50:
            return CompanionAction(id: rawValue, titleZh: "音量 50%", titleEn: "Volume 50%", sfSymbol: "speaker.wave.2.fill")
        case .volume75:
            return CompanionAction(id: rawValue, titleZh: "音量 75%", titleEn: "Volume 75%", sfSymbol: "speaker.wave.2.fill")
        case .volume100:
            return CompanionAction(id: rawValue, titleZh: "音量 100%", titleEn: "Volume 100%", sfSymbol: "speaker.wave.3.fill")
        case .toggleRepeat:
            return CompanionAction(id: rawValue, titleZh: "切换循环播放", titleEn: "Toggle Repeat", sfSymbol: "repeat")
        }
    }

    public var seekKind: MediaCompanionSeekKind? {
        switch self {
        case .seekBack30:
            return .relative(deltaSeconds: -30.0)
        case .seekForward30:
            return .relative(deltaSeconds: 30.0)
        case .seekBack60:
            return .relative(deltaSeconds: -60.0)
        case .seekForward60:
            return .relative(deltaSeconds: 60.0)
        case .restartTrack:
            return .restartTrack
        case .volume25, .volume50, .volume75, .volume100, .toggleRepeat:
            return nil
        }
    }

    public var volumeLevel: Double? {
        switch self {
        case .volume25:
            return 0.25
        case .volume50:
            return 0.50
        case .volume75:
            return 0.75
        case .volume100:
            return 1.0
        case .seekBack30, .seekForward30, .seekBack60, .seekForward60, .restartTrack, .toggleRepeat:
            return nil
        }
    }

    public func seekTarget(
        positionSeconds: Double?,
        durationSeconds: Double?
    ) -> Result<Double, NowPlayingRelativeSeekFailure> {
        guard let seekKind else {
            return .failure(.invalidDelta)
        }
        guard let positionSeconds,
              positionSeconds.isFinite,
              !positionSeconds.isNaN,
              positionSeconds >= 0 else {
            return .failure(.missingPosition)
        }
        guard let durationSeconds,
              durationSeconds.isFinite,
              !durationSeconds.isNaN,
              durationSeconds > 0 else {
            return .failure(.missingDuration)
        }
        switch seekKind {
        case .relative(let deltaSeconds):
            return MacMediaSeekRouter.relativeTargetPosition(
                positionSeconds: positionSeconds,
                durationSeconds: durationSeconds,
                deltaSeconds: deltaSeconds
            )
        case .restartTrack:
            return .success(MacMediaSeekRouter.clampPosition(0.0, durationSeconds: durationSeconds))
        }
    }

    /// Cycles Now Playing repeat mode `off -> one -> all -> off`, returning `nil` when current repeat is unknown.
    public static func nextRepeatMode(after current: NowPlayingRepeatMode?) -> NowPlayingRepeatMode? {
        guard let current else { return nil }
        switch current {
        case .off:
            return .one
        case .one:
            return .all
        case .all:
            return .off
        }
    }

    /// Resolves the next supported repeat mode in `off -> one -> all -> off` for a concrete player.
    public static func nextRepeatMode(
        after current: NowPlayingRepeatMode?,
        for target: MacMediaPlaybackModeTargetPlayer?
    ) -> NowPlayingRepeatMode? {
        guard let firstCandidate = nextRepeatMode(after: current) else {
            return nil
        }
        guard let target, !target.supportsRepeatMode(firstCandidate) else {
            return firstCandidate
        }
        guard let secondCandidate = nextRepeatMode(after: firstCandidate),
              target.supportsRepeatMode(secondCandidate) else {
            return nil
        }
        return secondCandidate
    }

    public static func volumeOutcome(
        level: Double,
        didSet: Bool,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        let percent = ControlStripLevel.percentage(for: level)
        if didSet {
            return (
                true,
                L10n.tr("系统音量已设为 \(percent)%", "System volume set to \(percent)%", language: language)
            )
        }
        return (
            false,
            L10n.tr("无法将系统音量设为 \(percent)%", "Could not set system volume to \(percent)%", language: language)
        )
    }

    public static func execute(
        id: String,
        language: AppLanguage = .system,
        readSeekSession: () -> MediaCompanionSeekSession,
        performSeek: (Double) -> (success: Bool, message: String),
        setVolume: (Double) -> Bool,
        readRepeatSession: () -> MediaCompanionRepeatSession,
        performSetRepeat: (NowPlayingRepeatMode) -> (success: Bool, message: String)
    ) -> (success: Bool, message: String) {
        guard let action = MediaCompanionAction(rawValue: id) else {
            return (false, L10n.tr("不支持此操作", "Unsupported action", language: language))
        }

        if action.seekKind != nil {
            let session = readSeekSession()
            switch action.seekTarget(
                positionSeconds: session.positionSeconds,
                durationSeconds: session.durationSeconds
            ) {
            case .failure(let failure):
                if action == .restartTrack && failure == .missingPosition {
                    return (
                        false,
                        L10n.tr(
                            "当前播放位置未知，无法重播当前曲目",
                            "Current playback position is unknown",
                            language: language
                        )
                    )
                }
                return (false, failure.message(in: language))
            case .success(let targetSeconds):
                return performSeek(targetSeconds)
            }
        }

        if let level = action.volumeLevel {
            let didSet = setVolume(level)
            return volumeOutcome(level: level, didSet: didSet, language: language)
        }

        let repeatSession = readRepeatSession()
        guard let nextMode = nextRepeatMode(
            after: repeatSession.currentRepeat,
            for: repeatSession.target
        ) else {
            let detail = repeatSession.failureMessage ?? L10n.tr(
                "当前播放器无法报告循环播放状态",
                "Current player cannot report repeat mode",
                language: language
            )
            return (false, detail)
        }
        return performSetRepeat(nextMode)
    }
}

extension CompanionActionCatalog {
    public static let mediaPack: [CompanionAction] = MediaCompanionAction.allCases.map(\.companionAction)
}
