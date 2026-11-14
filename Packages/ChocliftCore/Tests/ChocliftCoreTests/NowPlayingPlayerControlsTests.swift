import Foundation
import XCTest
@testable import ChocliftCore

@MainActor
final class NowPlayingPlayerControlsTests: XCTestCase {

    // Valid 1x1 transparent PNG for testing real image decoding via DataImageView.swiftUIImage(from:)
    private static let sampleValidPNGData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    // MARK: - 1. Cached Mac App Icon Resolution (Real Icon vs Generic Note Fallback)

    func testCachedAppIconResolutionReturnsCachedPNGAndNilWhenMissing() {
        let suiteName = "com.choclift.player.icon.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let client = CompanionClientEngine(
            deviceID: "iphone-icon-test",
            deviceName: "iPhone Icon",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "icon-test"
        )

        // When no icon is cached in appIconsByBundleID, even known bundle IDs return nil so the generic note shows
        XCTAssertNil(client.cachedAppIconData(forBundleIdentifier: nil))
        XCTAssertNil(client.cachedAppIconData(forBundleIdentifier: "   "))
        XCTAssertNil(client.cachedAppIconData(forBundleIdentifier: "com.apple.Music"))
        XCTAssertNil(client.cachedAppIconData(forBundleIdentifier: "com.spotify.client"))
        XCTAssertNil(client.cachedAppIconData(forBundleIdentifier: "org.videolan.vlc"))

        // Once the Mac app icon is cached for that bundle ID, cachedAppIconData returns it and builds a valid Image
        client.cacheAppIconData(Self.sampleValidPNGData, forBundleIdentifier: "com.spotify.client")
        let cachedSpotify = client.cachedAppIconData(forBundleIdentifier: "com.spotify.client")
        XCTAssertEqual(cachedSpotify, Self.sampleValidPNGData)
        XCTAssertEqual(
            client.cachedAppIconData(forBundleIdentifier: "COM.SPOTIFY.CLIENT"),
            Self.sampleValidPNGData,
            "Bundle ID lookup should tolerate case differences"
        )
        XCTAssertNotNil(DataImageView.swiftUIImage(from: Self.sampleValidPNGData))
        XCTAssertNil(DataImageView.swiftUIImage(from: Data([0x00, 0x01, 0x02])))

        // Uncached players continue to return nil (falling back to generic music.note)
        XCTAssertNil(client.cachedAppIconData(forBundleIdentifier: "org.videolan.vlc"))
    }

    // MARK: - 2. Shuffle & Repeat Visibility Strictly Restricted to Music & Spotify

    func testShuffleAndRepeatVisibilityStrictlyRestrictedToMusicAndSpotify() throws {
        let music = NowPlayingStatus(
            title: "One More Time",
            artist: "Daft Punk",
            appName: "Music",
            isPlaying: true,
            bundleIdentifier: "com.apple.Music",
            shuffleEnabled: true,
            repeatMode: .one
        )
        XCTAssertTrue(music.supportsShuffleAndRepeat)
        XCTAssertEqual(music.shuffleEnabled, true)
        XCTAssertEqual(music.repeatMode, .one)
        XCTAssertEqual(music.repeatMode?.symbolName, "repeat.1")

        let spotify = NowPlayingStatus(
            title: "Digital Love",
            artist: "Daft Punk",
            appName: "Spotify",
            isPlaying: true,
            bundleIdentifier: "com.spotify.client",
            shuffleEnabled: false,
            repeatMode: .all
        )
        XCTAssertTrue(spotify.supportsShuffleAndRepeat)
        XCTAssertEqual(spotify.shuffleEnabled, false)
        XCTAssertEqual(spotify.repeatMode, .all)
        XCTAssertEqual(spotify.repeatMode?.symbolName, "repeat")

        // Case-insensitive bundle ID match
        let lowerMusic = NowPlayingStatus(appName: "Music", isPlaying: true, bundleIdentifier: "com.apple.music")
        XCTAssertTrue(lowerMusic.supportsShuffleAndRepeat)

        // All other players do NOT show shuffle or repeat buttons and strip unsupported mode fields
        for otherBundle in [
            "com.apple.Safari",
            "com.google.Chrome",
            "org.videolan.vlc",
            "com.apple.podcasts",
            "tv.twitch.desktop",
            "",
            nil
        ] {
            let status = NowPlayingStatus(
                title: "Clip",
                appName: "Other Player",
                isPlaying: true,
                bundleIdentifier: otherBundle,
                shuffleEnabled: true,
                repeatMode: .all
            )
            XCTAssertFalse(status.supportsShuffleAndRepeat, "Bundle \(String(describing: otherBundle)) must not show shuffle/repeat")
            XCTAssertNil(status.shuffleEnabled)
            XCTAssertNil(status.repeatMode)
        }

        // Codable round-trip preserves shuffleEnabled & repeatMode for supported players
        let encoded = try JSONEncoder().encode(music)
        let decoded = try JSONDecoder().decode(NowPlayingStatus.self, from: encoded)
        XCTAssertEqual(decoded, music)
        XCTAssertEqual(decoded.shuffleEnabled, true)
        XCTAssertEqual(decoded.repeatMode, .one)
    }

    // MARK: - 3. Public AppleEvent Scripts, Repeat Cycling & Non-Optimistic State Helpers

    func testPublicAppleEventScriptsAndRepeatCyclesForMusicAndSpotify() {
        // Music repeat cycle: off -> all -> one -> off
        XCTAssertEqual(MacMediaPlaybackModeTargetPlayer.music.nextRepeatMode(after: nil), .all)
        XCTAssertEqual(MacMediaPlaybackModeTargetPlayer.music.nextRepeatMode(after: .off), .all)
        XCTAssertEqual(MacMediaPlaybackModeTargetPlayer.music.nextRepeatMode(after: .all), .one)
        XCTAssertEqual(MacMediaPlaybackModeTargetPlayer.music.nextRepeatMode(after: .one), .off)

        // Spotify repeat cycle (boolean `repeating` in Spotify.sdef): off -> all -> off
        XCTAssertEqual(MacMediaPlaybackModeTargetPlayer.spotify.nextRepeatMode(after: nil), .all)
        XCTAssertEqual(MacMediaPlaybackModeTargetPlayer.spotify.nextRepeatMode(after: .off), .all)
        XCTAssertEqual(MacMediaPlaybackModeTargetPlayer.spotify.nextRepeatMode(after: .all), .off)

        // Music public AppleEvent read & write scripts
        let musicRead = MacMediaPlaybackModeTargetPlayer.music.readPlaybackModesScriptSource()
        XCTAssertTrue(musicRead.contains(#"if application id "com.apple.Music" is running then"#))
        XCTAssertTrue(musicRead.contains("shuffle enabled"))
        XCTAssertTrue(musicRead.contains("song repeat"))
        XCTAssertFalse(musicRead.lowercased().contains("activate"))
        XCTAssertFalse(musicRead.contains("MediaRemote"))

        let musicWriteShuffleOn = MacMediaPlaybackModeTargetPlayer.music.writeShuffleScriptSource(enabled: true)
        XCTAssertTrue(musicWriteShuffleOn.contains(#"if application id "com.apple.Music" is running then"#))
        XCTAssertTrue(musicWriteShuffleOn.contains(#"tell application id "com.apple.Music" to set shuffle enabled to true"#))
        XCTAssertFalse(musicWriteShuffleOn.lowercased().contains("activate"))

        XCTAssertEqual(
            MacMediaPlaybackModeTargetPlayer.music.writeRepeatScriptSource(mode: .off)?.contains("set song repeat to off"),
            true
        )
        XCTAssertEqual(
            MacMediaPlaybackModeTargetPlayer.music.writeRepeatScriptSource(mode: .all)?.contains("set song repeat to all"),
            true
        )
        XCTAssertEqual(
            MacMediaPlaybackModeTargetPlayer.music.writeRepeatScriptSource(mode: .one)?.contains("set song repeat to one"),
            true
        )

        // Spotify public AppleEvent read & write scripts
        let spotifyRead = MacMediaPlaybackModeTargetPlayer.spotify.readPlaybackModesScriptSource()
        XCTAssertTrue(spotifyRead.contains(#"if application id "com.spotify.client" is running then"#))
        XCTAssertTrue(spotifyRead.contains("if shuffling then"))
        XCTAssertTrue(spotifyRead.contains("if repeating then"))
        XCTAssertFalse(spotifyRead.lowercased().contains("activate"))
        XCTAssertFalse(spotifyRead.contains("MediaRemote"))

        let spotifyWriteShuffleOff = MacMediaPlaybackModeTargetPlayer.spotify.writeShuffleScriptSource(enabled: false)
        XCTAssertTrue(spotifyWriteShuffleOff.contains(#"if application id "com.spotify.client" is running then"#))
        XCTAssertTrue(spotifyWriteShuffleOff.contains(#"tell application id "com.spotify.client" to set shuffling to false"#))
        XCTAssertFalse(spotifyWriteShuffleOff.lowercased().contains("activate"))

        XCTAssertEqual(
            MacMediaPlaybackModeTargetPlayer.spotify.writeRepeatScriptSource(mode: .off)?.contains("set repeating to false"),
            true
        )
        XCTAssertEqual(
            MacMediaPlaybackModeTargetPlayer.spotify.writeRepeatScriptSource(mode: .all)?.contains("set repeating to true"),
            true
        )
        XCTAssertNil(
            MacMediaPlaybackModeTargetPlayer.spotify.writeRepeatScriptSource(mode: .one),
            "Spotify public AppleEvent dictionary has boolean repeating only"
        )

        // Token parser
        let parsedMusic = MacMediaPlaybackModeRouter.parsePlaybackModes(shuffleToken: "true", repeatToken: "one")
        XCTAssertEqual(parsedMusic?.shuffleEnabled, true)
        XCTAssertEqual(parsedMusic?.repeatMode, .one)
        let parsedSpotify = MacMediaPlaybackModeRouter.parsePlaybackModes(shuffleToken: "false", repeatToken: "all")
        XCTAssertEqual(parsedSpotify?.shuffleEnabled, false)
        XCTAssertEqual(parsedSpotify?.repeatMode, .all)
        XCTAssertNil(MacMediaPlaybackModeRouter.parsePlaybackModes(shuffleToken: "NOT_RUNNING", repeatToken: "NOT_RUNNING"))

        // Non-optimistic state transitions never flip on failed writes
        let initial = NowPlayingStatus(
            title: "Voyager",
            artist: "Daft Punk",
            appName: "Music",
            isPlaying: true,
            bundleIdentifier: "com.apple.Music",
            shuffleEnabled: false,
            repeatMode: .off
        )
        XCTAssertEqual(NowPlayingStatus.afterShuffleChange(initial, enabled: true, success: false), initial)
        XCTAssertEqual(NowPlayingStatus.afterRepeatChange(initial, mode: .all, success: false), initial)
        XCTAssertEqual(NowPlayingStatus.afterShuffleChange(initial, enabled: true, success: true)?.shuffleEnabled, true)
        XCTAssertEqual(NowPlayingStatus.afterRepeatChange(initial, mode: .one, success: true)?.repeatMode, .one)

        // Router rejections for non-running or unsupported apps
        XCTAssertEqual(
            MacMediaPlaybackModeRouter.chooseShuffleRoute(
                enabled: true,
                context: MacMediaPlaybackModeContext(nowPlayingBundleID: "com.spotify.client", isSpotifyRunning: false, isMusicRunning: false)
            ),
            .rejected(.playerNotRunning(bundleID: "com.spotify.client"))
        )
        XCTAssertEqual(
            MacMediaPlaybackModeRouter.chooseRepeatRoute(
                mode: .all,
                context: MacMediaPlaybackModeContext(nowPlayingBundleID: "com.apple.Safari", isSpotifyRunning: true, isMusicRunning: true)
            ),
            .rejected(.unsupportedPlayer(bundleID: "com.apple.Safari"))
        )
    }

    // MARK: - 4. Loopback Integration: Cached Icon, Activate App, Shuffle/Repeat Read/Write & Real Error Without Flipping Icon

    func testLoopbackActivateAppShuffleRepeatAndFailedWritePreservesIconAndShowsRealError() async throws {
        XCTAssertEqual(ChocliftDefaults.protocolVersion, 3)

        let suiteName = "com.choclift.player.loopback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = PlayerControlsMockServerDelegate()
        delegate.iconsByBundleID = [
            "com.apple.Music": Self.sampleValidPNGData
        ]
        delegate.controlState = ControlStripState(
            volume: 0.5,
            isVolumeMuted: false,
            brightness: 0.75,
            isBrightnessAvailable: true,
            isMicMuted: false,
            nowPlaying: NowPlayingStatus(
                title: "Harder, Better, Faster, Stronger",
                artist: "Daft Punk",
                appName: "Music",
                isPlaying: true,
                elapsedSeconds: 18.0,
                durationSeconds: 224.0,
                bundleIdentifier: "com.apple.Music",
                shuffleEnabled: false,
                repeatMode: .off
            )
        )

        let server = MacServerEngine(macID: "mac-player-host", macName: "Studio Mac Player")
        server.delegate = delegate
        delegate.server = server
        defer { server.stop() }

        let (srvEnd, cliEnd) = InMemoryCompanionPipe.pair()
        server.acceptCompanionTransport(srvEnd, link: .bluetooth)
        let client = CompanionClientEngine(
            deviceID: "iphone-player",
            deviceName: "iPhone Player",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "iphone-player"
        )
        defer { client.disconnect() }

        client.connectInMemoryBluetooth(to: cliEnd, targetName: "Studio Mac Player")
        try await waitUntil("iPhone awaiting PIN") {
            if case .awaitingPIN = client.connectionState { return true }
            return false
        }
        client.submitPIN(server.currentPIN)
        try await waitUntil("iPhone synced Music Now Playing + cached Mac app icon") {
            client.connectionState.isConnected &&
            client.controlStripState.nowPlaying?.bundleIdentifier == "com.apple.Music" &&
            client.cachedAppIconData(forBundleIdentifier: "com.apple.Music") == Self.sampleValidPNGData
        }

        // 1. Tapping the player name asks the Mac to activate that app
        XCTAssertTrue(client.activateNowPlayingApp())
        try await waitUntil("Mac received activateRecentApp for com.apple.Music") {
            delegate.activatedApps.count == 1
        }
        XCTAssertEqual(delegate.activatedApps.first?.bundleID, "com.apple.Music")

        // 2. Successful shuffle toggle does NOT optimistically flip locally before reply, then flips when Mac confirms
        delegate.pauseReplies = true
        XCTAssertTrue(client.toggleNowPlayingShuffle())
        XCTAssertEqual(
            client.controlStripState.nowPlaying?.shuffleEnabled,
            false,
            "Shuffle icon must not optimistically flip before Mac AppleEvent write completes"
        )
        delegate.pauseReplies = false
        delegate.flushPausedReplies()
        try await waitUntil("Music shuffle flipped to true after Mac confirmation") {
            client.controlStripState.nowPlaying?.shuffleEnabled == true
        }
        XCTAssertNil(client.lastNowPlayingModeError)

        // 3. Successful Music repeat cycle: off -> all -> one -> off
        XCTAssertTrue(client.cycleNowPlayingRepeat())
        try await waitUntil("Music repeat -> all") {
            client.controlStripState.nowPlaying?.repeatMode == .all
        }
        XCTAssertEqual(client.controlStripState.nowPlaying?.repeatMode?.symbolName, "repeat")

        XCTAssertTrue(client.cycleNowPlayingRepeat())
        try await waitUntil("Music repeat -> one") {
            client.controlStripState.nowPlaying?.repeatMode == .one
        }
        XCTAssertEqual(client.controlStripState.nowPlaying?.repeatMode?.symbolName, "repeat.1")

        // 4. Failed shuffle write shows the real AppleEvent error and does NOT flip the icon
        let realShuffleError = "Not authorized to send Apple events to Music. (-1743)"
        delegate.simulatedWriteFailureMessage = realShuffleError
        XCTAssertTrue(client.toggleNowPlayingShuffle()) // attempts true -> false
        try await waitUntil("Failed shuffle write delivered real error") {
            client.lastFeedback?.success == false &&
            client.lastFeedback?.detail == realShuffleError
        }
        XCTAssertEqual(client.lastNowPlayingModeError, realShuffleError)
        XCTAssertEqual(
            client.controlStripState.nowPlaying?.shuffleEnabled,
            true,
            "Failed shuffle write must NOT flip shuffleEnabled"
        )

        // 5. Failed repeat write shows the real AppleEvent error and does NOT flip the icon
        let realRepeatError = "Music got an error: Can’t set song repeat to off. (-10006)"
        delegate.simulatedWriteFailureMessage = realRepeatError
        XCTAssertTrue(client.cycleNowPlayingRepeat()) // attempts one -> off
        try await waitUntil("Failed repeat write delivered real error") {
            client.lastFeedback?.success == false &&
            client.lastFeedback?.detail == realRepeatError
        }
        XCTAssertEqual(client.lastNowPlayingModeError, realRepeatError)
        XCTAssertEqual(
            client.controlStripState.nowPlaying?.repeatMode,
            .one,
            "Failed repeat write must NOT flip repeatMode"
        )

        // 6. Switching to a non-Music/non-Spotify player hides shuffle/repeat and blocks mode writes
        delegate.simulatedWriteFailureMessage = nil
        var vlcState = delegate.controlState
        vlcState.nowPlaying = NowPlayingStatus(
            title: "Big Buck Bunny",
            appName: "VLC",
            isPlaying: true,
            bundleIdentifier: "org.videolan.vlc"
        )
        delegate.controlState = vlcState
        server.broadcastControlStripState(vlcState)
        try await waitUntil("Client switched to VLC") {
            client.controlStripState.nowPlaying?.bundleIdentifier == "org.videolan.vlc"
        }
        XCTAssertFalse(client.controlStripState.nowPlaying?.supportsShuffleAndRepeat ?? true)
        XCTAssertNil(client.cachedAppIconData(forBundleIdentifier: "org.videolan.vlc"))
        XCTAssertNil(client.lastNowPlayingModeError)

        let priorShuffleWrites = delegate.receivedShuffleWrites.count
        let priorRepeatWrites = delegate.receivedRepeatWrites.count
        XCTAssertFalse(client.toggleNowPlayingShuffle())
        XCTAssertFalse(client.cycleNowPlayingRepeat())
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(delegate.receivedShuffleWrites.count, priorShuffleWrites)
        XCTAssertEqual(delegate.receivedRepeatWrites.count, priorRepeatWrites)
    }

    private func waitUntil(
        _ description: String,
        timeoutSeconds: TimeInterval = 3.0,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("Timed out waiting for: \(description)")
    }
}

@MainActor
private final class PlayerControlsMockServerDelegate: MacServerEngineDelegate {
    weak var server: MacServerEngine?
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var controlState: ControlStripState = ControlStripState()
    var iconsByBundleID: [String: Data] = [:]
    var activatedApps: [(bundleID: String, appPath: String?)] = []
    var receivedShuffleWrites: [Bool] = []
    var receivedRepeatWrites: [NowPlayingRepeatMode] = []
    var simulatedWriteFailureMessage: String?
    var pauseReplies = false
    private var queuedWork: [@MainActor () -> Void] = []

    func flushPausedReplies() {
        let work = queuedWork
        queuedWork.removeAll()
        for item in work {
            item()
        }
    }

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { nil }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (false, nil) }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverCurrentOrcaStatus() -> OrcaTaskStatusSnapshot? { nil }

    func serverIcons(for bundleIDs: [String]) -> [String: Data] {
        var out: [String: Data] = [:]
        for bid in bundleIDs {
            if let data = iconsByBundleID[bid] {
                out[bid] = data
            }
        }
        return out
    }

    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {}

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        let handle: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            switch message {
            case .requestControlStripState:
                reply(.controlStripStateUpdated(self.controlState))

            case .activateRecentApp(let bundleIdentifier, let appPath):
                self.activatedApps.append((bundleIdentifier, appPath))
                reply(.actionFeedback(success: true, title: bundleIdentifier, detail: "Activated"))

            case .setNowPlayingShuffle(let enabled):
                self.receivedShuffleWrites.append(enabled)
                if let failure = self.simulatedWriteFailureMessage {
                    reply(.controlStripStateUpdated(self.controlState))
                    reply(.actionFeedback(success: false, title: "Shuffle", detail: failure))
                } else {
                    self.controlState.nowPlaying = NowPlayingStatus.afterShuffleChange(
                        self.controlState.nowPlaying,
                        enabled: enabled,
                        success: true
                    )
                    reply(.controlStripStateUpdated(self.controlState))
                    self.server?.broadcastControlStripState(self.controlState, excludingDeviceID: device.deviceID)
                }

            case .setNowPlayingRepeat(let mode):
                self.receivedRepeatWrites.append(mode)
                if let failure = self.simulatedWriteFailureMessage {
                    reply(.controlStripStateUpdated(self.controlState))
                    reply(.actionFeedback(success: false, title: "Repeat", detail: failure))
                } else {
                    self.controlState.nowPlaying = NowPlayingStatus.afterRepeatChange(
                        self.controlState.nowPlaying,
                        mode: mode,
                        success: true
                    )
                    reply(.controlStripStateUpdated(self.controlState))
                    self.server?.broadcastControlStripState(self.controlState, excludingDeviceID: device.deviceID)
                }

            default:
                break
            }
        }

        if pauseReplies {
            queuedWork.append(handle)
        } else {
            handle()
        }
    }
}
