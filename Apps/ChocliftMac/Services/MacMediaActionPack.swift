import AppKit
import ChocliftCore
import Foundation

enum MacMediaActionPack {
    private struct LiveScriptedPlayerSnapshot {
        let bundleIdentifier: String
        let isPlaying: Bool
        let hasCurrentTrack: Bool
        let positionSeconds: Double?
        let durationSeconds: Double?
    }

    private struct ResolvedSeekSnapshot {
        let bundleIdentifier: String?
        let positionSeconds: Double?
        let durationSeconds: Double?
        let isSpotifyRunning: Bool
        let isMusicRunning: Bool
    }

    @MainActor private static let windowService = MacAccessibilityAndWindowService()
    @MainActor private static let systemControlService = MacSystemControlService()
    @MainActor private static var latestSeekContext = MacMediaSeekContext()
    @MainActor private static var latestPlaybackModeContext = MacMediaPlaybackModeContext()

    @MainActor private static let inputService: MacInputAndMediaService = {
        let service = MacInputAndMediaService(windowService: windowService)
        service.mediaSeekContextProvider = { latestSeekContext }
        service.mediaPlaybackModeContextProvider = { latestPlaybackModeContext }
        return service
    }()

    /// Pure clamped seek target calculation for `0...durationSeconds`, failing when position or duration is missing.
    static func clampedSeekTarget(
        positionSeconds: Double?,
        durationSeconds: Double?,
        deltaSeconds: Double
    ) -> Result<Double, NowPlayingRelativeSeekFailure> {
        guard let positionSeconds,
              positionSeconds.isFinite,
              !positionSeconds.isNaN,
              positionSeconds >= 0 else {
            return .failure(.missingPosition)
        }
        return MacMediaSeekRouter.relativeTargetPosition(
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            deltaSeconds: deltaSeconds
        )
    }

    static func clampedSeekTarget(
        for action: MediaCompanionAction,
        positionSeconds: Double?,
        durationSeconds: Double?
    ) -> Result<Double, NowPlayingRelativeSeekFailure> {
        action.seekTarget(positionSeconds: positionSeconds, durationSeconds: durationSeconds)
    }

    static func run(id: String) -> (success: Bool, message: String) {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                runOnMainActor(id: id)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                runOnMainActor(id: id)
            }
        }
    }

    @MainActor
    private static func runOnMainActor(id: String) -> (success: Bool, message: String) {
        var resolvedSeek: ResolvedSeekSnapshot?
        return MediaCompanionAction.execute(
            id: id,
            readSeekSession: {
                let snapshot = readResolvedSeekSnapshot()
                resolvedSeek = snapshot
                return MediaCompanionSeekSession(
                    positionSeconds: snapshot.positionSeconds,
                    durationSeconds: snapshot.durationSeconds
                )
            },
            performSeek: { targetSeconds in
                let snapshot = resolvedSeek ?? readResolvedSeekSnapshot()
                latestSeekContext = MacMediaSeekContext(
                    nowPlayingBundleID: snapshot.bundleIdentifier,
                    durationSeconds: snapshot.durationSeconds,
                    isSpotifyRunning: snapshot.isSpotifyRunning,
                    isMusicRunning: snapshot.isMusicRunning
                )
                let res = inputService.seekNowPlaying(to: targetSeconds)
                return (res.success, res.message)
            },
            setVolume: { level in
                systemControlService.setVolume(level: level)
            },
            readRepeatSession: {
                readLiveRepeatSession()
            },
            performSetRepeat: { nextMode in
                let res = inputService.setNowPlayingRepeat(mode: nextMode)
                return (res.success, res.message)
            }
        )
    }

    @MainActor
    private static func readResolvedSeekSnapshot() -> ResolvedSeekSnapshot {
        let spotifyID = MacMediaSeekRouter.spotifyBundleIdentifier
        let musicID = MacMediaSeekRouter.musicBundleIdentifier
        let spotifyRunning = isAppRunning(bundleID: spotifyID)
        let musicRunning = isAppRunning(bundleID: musicID)

        let spotifySnap = spotifyRunning ? readScriptedPlayerSnapshot(bundleID: spotifyID, durationInMilliseconds: true) : nil
        let musicSnap = musicRunning ? readScriptedPlayerSnapshot(bundleID: musicID, durationInMilliseconds: false) : nil
        let transportContext = systemControlService.currentMediaTransportContext()

        let chosen: LiveScriptedPlayerSnapshot? = {
            if let spotifySnap, spotifySnap.isPlaying, spotifySnap.hasCurrentTrack {
                return spotifySnap
            }
            if let musicSnap, musicSnap.isPlaying, musicSnap.hasCurrentTrack {
                return musicSnap
            }
            if let activeBundle = transportContext.nowPlayingBundleID,
               !MacMediaSeekRouter.isSupportedSeekBundleIdentifier(activeBundle) {
                return nil
            }
            if let spotifySnap, spotifySnap.hasCurrentTrack {
                return spotifySnap
            }
            if let musicSnap, musicSnap.hasCurrentTrack {
                return musicSnap
            }
            return nil
        }()

        let activeBundle = chosen?.bundleIdentifier ?? transportContext.nowPlayingBundleID
        return ResolvedSeekSnapshot(
            bundleIdentifier: activeBundle,
            positionSeconds: chosen?.positionSeconds,
            durationSeconds: chosen?.durationSeconds,
            isSpotifyRunning: spotifyRunning,
            isMusicRunning: musicRunning
        )
    }

    @MainActor
    private static func readLiveRepeatSession() -> MediaCompanionRepeatSession {
        let snapshot = readResolvedSeekSnapshot()
        latestPlaybackModeContext = MacMediaPlaybackModeContext(
            nowPlayingBundleID: snapshot.bundleIdentifier,
            isSpotifyRunning: snapshot.isSpotifyRunning,
            isMusicRunning: snapshot.isMusicRunning
        )

        guard let bundleID = snapshot.bundleIdentifier else {
            return MediaCompanionRepeatSession(
                failureMessage: MacMediaPlaybackModeRejectionReason.noActiveMediaPlayer.message()
            )
        }
        guard let target = MacMediaPlaybackModeTargetPlayer(bundleIdentifier: bundleID) else {
            return MediaCompanionRepeatSession(
                failureMessage: MacMediaPlaybackModeRejectionReason.unsupportedPlayer(bundleID: bundleID).message()
            )
        }
        guard isAppRunning(bundleID: target.bundleIdentifier) else {
            return MediaCompanionRepeatSession(
                target: target,
                failureMessage: MacMediaPlaybackModeRejectionReason.playerNotRunning(bundleID: target.bundleIdentifier).message()
            )
        }

        let source = """
        with timeout of 2 seconds
            \(target.readPlaybackModesScriptSource())
        end timeout
        """
        guard let script = NSAppleScript(source: source) else {
            return MediaCompanionRepeatSession(target: target)
        }
        var errorDict: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorDict)
        if let errorDict {
            let reason = ((errorDict[NSAppleScript.errorBriefMessage] as? String)
                ?? (errorDict[NSAppleScript.errorMessage] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MediaCompanionRepeatSession(
                target: target,
                failureMessage: (reason?.isEmpty == false) ? reason : nil
            )
        }
        guard descriptor.numberOfItems == 2,
              let parsed = MacMediaPlaybackModeRouter.parsePlaybackModes(
                  shuffleToken: descriptor.atIndex(1)?.stringValue,
                  repeatToken: descriptor.atIndex(2)?.stringValue
              ) else {
            return MediaCompanionRepeatSession(target: target)
        }
        return MediaCompanionRepeatSession(target: target, currentRepeat: parsed.repeatMode)
    }

    private static func readScriptedPlayerSnapshot(
        bundleID: String,
        durationInMilliseconds: Bool
    ) -> LiveScriptedPlayerSnapshot? {
        guard isAppRunning(bundleID: bundleID) else { return nil }
        let source = """
        with timeout of 2 seconds
            if application id "\(bundleID)" is running then
                tell application id "\(bundleID)"
                    set playbackState to player state as text
                    set trackName to ""
                    try
                        set trackName to name of current track
                    end try
                    set posValue to -1.0
                    try
                        set posValue to (player position) as real
                    end try
                    set durValue to -1.0
                    try
                        set durValue to (duration of current track) as real
                    end try
                    return {playbackState, trackName, posValue, durValue}
                end tell
            else
                return {"NOT_RUNNING", "", -1.0, -1.0}
            end if
        end timeout
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorDict: NSDictionary?
        let result = script.executeAndReturnError(&errorDict)
        guard errorDict == nil, result.numberOfItems == 4 else { return nil }

        let rawState = (result.atIndex(1)?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawState != "NOT_RUNNING" else { return nil }
        let trackTitle = (result.atIndex(2)?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTrack = !trackTitle.isEmpty
        let rawPos = result.atIndex(3)?.doubleValue ?? -1.0
        let rawDur = result.atIndex(4)?.doubleValue ?? -1.0

        let position: Double? = (hasTrack && rawPos.isFinite && !rawPos.isNaN && rawPos >= 0) ? rawPos : nil
        let scaledDur = durationInMilliseconds ? (rawDur / 1000.0) : rawDur
        let duration: Double? = (hasTrack && scaledDur.isFinite && !scaledDur.isNaN && scaledDur > 0) ? scaledDur : nil

        return LiveScriptedPlayerSnapshot(
            bundleIdentifier: bundleID,
            isPlaying: rawState.lowercased() == "playing",
            hasCurrentTrack: hasTrack,
            positionSeconds: position,
            durationSeconds: duration
        )
    }

    private static func isAppRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains(where: { !$0.isTerminated })
    }
}
