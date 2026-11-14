import Foundation
import XCTest
@testable import ChocliftCore

@MainActor
final class NowPlayingScrubTests: XCTestCase {
    private struct TimeoutError: Error, LocalizedError {
        let label: String
        var errorDescription: String? { "Timed out waiting for: \(label)" }
    }

    // MARK: - 1. Seek Router: Spotify, Music, Unknown Bundle, Missing Duration

    func testSeekRouterSpotifyMusicUnknownBundleAndMissingDuration() {
        // 1. Spotify bundle + running -> background Spotify script seek
        let spotifyRunningRoute = MacMediaSeekRouter.chooseRoute(
            requestedPositionSeconds: 83.45,
            nowPlayingBundleID: "com.spotify.client",
            durationSeconds: 244.0,
            isSpotifyRunning: true,
            isMusicRunning: false
        )
        XCTAssertEqual(spotifyRunningRoute, .spotifyScript(positionSeconds: 83.45))

        let spotifyScript = MacMediaSeekTargetPlayer.spotify.scriptSource(positionSeconds: 83.45)
        XCTAssertTrue(spotifyScript.contains(#"if application id "com.spotify.client" is running then"#))
        XCTAssertTrue(spotifyScript.contains(#"tell application id "com.spotify.client" to set player position to 83.450"#))
        XCTAssertFalse(spotifyScript.lowercased().contains("activate"))

        // Spotify bundle + NOT running -> rejected (never launches Spotify)
        let spotifyStoppedRoute = MacMediaSeekRouter.chooseRoute(
            requestedPositionSeconds: 83.45,
            nowPlayingBundleID: "com.spotify.client",
            durationSeconds: 244.0,
            isSpotifyRunning: false,
            isMusicRunning: true
        )
        XCTAssertEqual(
            spotifyStoppedRoute,
            .rejected(.playerNotRunning(bundleID: "com.spotify.client"))
        )

        // 2. Music bundle + running -> background Music script seek
        let musicRunningRoute = MacMediaSeekRouter.chooseRoute(
            requestedPositionSeconds: 120.25,
            nowPlayingBundleID: "com.apple.Music",
            durationSeconds: 300.0,
            isSpotifyRunning: true,
            isMusicRunning: true
        )
        XCTAssertEqual(musicRunningRoute, .musicScript(positionSeconds: 120.25))

        let musicScript = MacMediaSeekTargetPlayer.music.scriptSource(positionSeconds: 120.25)
        XCTAssertTrue(musicScript.contains(#"if application id "com.apple.Music" is running then"#))
        XCTAssertTrue(musicScript.contains(#"tell application id "com.apple.Music" to set player position to 120.250"#))
        XCTAssertFalse(musicScript.lowercased().contains("activate"))

        // Music bundle + NOT running -> rejected (never launches Music)
        let musicStoppedRoute = MacMediaSeekRouter.chooseRoute(
            requestedPositionSeconds: 120.25,
            nowPlayingBundleID: "com.apple.Music",
            durationSeconds: 300.0,
            isSpotifyRunning: true,
            isMusicRunning: false
        )
        XCTAssertEqual(
            musicStoppedRoute,
            .rejected(.playerNotRunning(bundleID: "com.apple.Music"))
        )

        // 3. Unknown / non-seekable bundles -> no script and no fake success, even if Spotify & Music are running
        for unsupportedBundle in ["com.apple.Safari", "org.videolan.vlc", "com.apple.podcasts", "com.google.Chrome"] {
            let route = MacMediaSeekRouter.chooseRoute(
                requestedPositionSeconds: 45.0,
                nowPlayingBundleID: unsupportedBundle,
                durationSeconds: 210.0,
                isSpotifyRunning: true,
                isMusicRunning: true
            )
            XCTAssertEqual(route, .rejected(.unsupportedPlayer(bundleID: unsupportedBundle)))

            let status = NowPlayingStatus(
                title: "Web Lecture",
                artist: "Channel",
                appName: "Browser",
                isPlaying: true,
                elapsedSeconds: 83,
                durationSeconds: 244,
                bundleIdentifier: unsupportedBundle
            )
            XCTAssertFalse(status.isSeekable, "\(unsupportedBundle) must not show a draggable scrub track on macOS 13")
            XCTAssertEqual(status.formattedProgressText, "1:23 / 4:04", "Unsupported app keeps read-only progress label")
        }

        // Nil / blank bundle -> rejected with noActiveMediaPlayer (never falls back to background Spotify)
        XCTAssertEqual(
            MacMediaSeekRouter.chooseRoute(
                requestedPositionSeconds: 30.0,
                nowPlayingBundleID: nil,
                durationSeconds: 200.0,
                isSpotifyRunning: true,
                isMusicRunning: true
            ),
            .rejected(.noActiveMediaPlayer)
        )
        XCTAssertEqual(
            MacMediaSeekRouter.chooseRoute(
                requestedPositionSeconds: 30.0,
                nowPlayingBundleID: "   ",
                durationSeconds: 200.0,
                isSpotifyRunning: true,
                isMusicRunning: true
            ),
            .rejected(.noActiveMediaPlayer)
        )

        // 4. Missing or invalid duration -> seek rejected and draggable track suppressed
        let missingDurations: [Double?] = [nil, 0.0, -15.0, .nan, .infinity, -.infinity]
        for badDuration in missingDurations {
            let route = MacMediaSeekRouter.chooseRoute(
                requestedPositionSeconds: 20.0,
                nowPlayingBundleID: "com.spotify.client",
                durationSeconds: badDuration,
                isSpotifyRunning: true,
                isMusicRunning: true
            )
            XCTAssertEqual(route, .rejected(.missingDuration))

            let status = NowPlayingStatus(
                title: "Live Radio Stream",
                appName: "Spotify",
                isPlaying: true,
                elapsedSeconds: 20.0,
                durationSeconds: badDuration,
                bundleIdentifier: "com.spotify.client"
            )
            XCTAssertFalse(status.isSeekable)
            XCTAssertNil(status.progressFraction)
            XCTAssertNil(status.formattedProgressText)
        }
    }

    // MARK: - 2. Clamp: Negative, NaN, In-Range, and Past-End Positions

    func testSeekPositionClampingNegativeAndPastEnd() {
        let duration = 244.0

        // Negative & NaN clamp to 0
        XCTAssertEqual(MacMediaSeekRouter.clampPosition(-0.001, durationSeconds: duration), 0.0, accuracy: 1e-9)
        XCTAssertEqual(MacMediaSeekRouter.clampPosition(-48.5, durationSeconds: duration), 0.0, accuracy: 1e-9)
        XCTAssertEqual(MacMediaSeekRouter.clampPosition(-.infinity, durationSeconds: duration), 0.0, accuracy: 1e-9)
        XCTAssertEqual(MacMediaSeekRouter.clampPosition(.nan, durationSeconds: duration), 0.0, accuracy: 1e-9)

        // Past-end & +infinity clamp to duration
        XCTAssertEqual(MacMediaSeekRouter.clampPosition(244.001, durationSeconds: duration), duration, accuracy: 1e-9)
        XCTAssertEqual(MacMediaSeekRouter.clampPosition(999.0, durationSeconds: duration), duration, accuracy: 1e-9)
        XCTAssertEqual(MacMediaSeekRouter.clampPosition(.infinity, durationSeconds: duration), duration, accuracy: 1e-9)

        // Exact boundaries and interior positions preserved
        XCTAssertEqual(MacMediaSeekRouter.clampPosition(0.0, durationSeconds: duration), 0.0, accuracy: 1e-9)
        XCTAssertEqual(MacMediaSeekRouter.clampPosition(122.75, durationSeconds: duration), 122.75, accuracy: 1e-9)
        XCTAssertEqual(MacMediaSeekRouter.clampPosition(duration, durationSeconds: duration), duration, accuracy: 1e-9)

        // Router also clamps negative and past-end positions before producing the script route
        XCTAssertEqual(
            MacMediaSeekRouter.chooseRoute(
                requestedPositionSeconds: -25.0,
                nowPlayingBundleID: "com.spotify.client",
                durationSeconds: duration,
                isSpotifyRunning: true,
                isMusicRunning: false
            ),
            .spotifyScript(positionSeconds: 0.0)
        )
        XCTAssertEqual(
            MacMediaSeekRouter.chooseRoute(
                requestedPositionSeconds: 600.0,
                nowPlayingBundleID: "com.apple.Music",
                durationSeconds: duration,
                isSpotifyRunning: false,
                isMusicRunning: true
            ),
            .musicScript(positionSeconds: duration)
        )
    }

    // MARK: - 3. Drag Release Encodes Exactly One Seek (Not One Per Pixel) Across Phone, iPad & Watch

    func testMultiPixelDragEncodesSingleSeekOnReleaseAcrossPhoneIPadAndWatchAndKeepsProtocolSafety() async throws {
        XCTAssertEqual(ChocliftDefaults.protocolVersion, 3, "Protocol version must remain unchanged (v3)")

        let suiteName = "com.choclift.scrub.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let delegate = ScrubMockServerDelegate()
        delegate.controlState = ControlStripState(
            volume: 0.62,
            isVolumeMuted: false,
            brightness: 0.80,
            isBrightnessAvailable: true,
            isMicMuted: false,
            nowPlaying: NowPlayingStatus(
                title: "Veridis Quo",
                artist: "Daft Punk",
                appName: "Spotify",
                isPlaying: true,
                elapsedSeconds: 40.0,
                durationSeconds: 345.0,
                bundleIdentifier: "com.spotify.client"
            )
        )

        let server = MacServerEngine(macID: "mac-scrub-host", macName: "Studio Mac Scrub")
        server.delegate = delegate
        delegate.server = server
        defer { server.stop() }

        // Verify pre-auth unknown frame still disconnects immediately
        let (unauthServerEnd, unauthClientEnd) = InMemoryCompanionPipe.pair()
        var unauthClosed = false
        unauthClientEnd.onClosed = { unauthClosed = true }
        server.acceptCompanionTransport(unauthServerEnd, link: .bluetooth)
        unauthClientEnd.start()
        let unknownPreAuth = Data(#"{"futurePreAuthFrame":{"v":1}}"#.utf8)
        unauthClientEnd.send(Self.wrapRawFrame(unknownPreAuth))
        try await waitUntil("pre-auth unknown frame disconnected") { unauthClosed }

        // Pair and connect iPhone, iPad, and Watch companions
        let companions: [(CompanionClientEngine, InMemoryCompanionPipe)] = try await [
            (.iPhone, "iphone-scrub", "iPhone Scrub"),
            (.iPad, "ipad-scrub", "iPad Scrub"),
            (.appleWatch, "watch-scrub", "Watch Scrub")
        ].asyncMap { platform, devID, devName in
            let (srvEnd, cliEnd) = InMemoryCompanionPipe.pair()
            server.acceptCompanionTransport(srvEnd, link: .bluetooth)
            let client = CompanionClientEngine(
                deviceID: devID,
                deviceName: devName,
                platform: platform,
                userDefaults: defaults,
                storageKeyPrefix: devID
            )
            client.connectInMemoryBluetooth(to: cliEnd, targetName: "Studio Mac Scrub")
            try await self.waitUntil("\(devName) awaiting PIN") {
                if case .awaitingPIN = client.connectionState { return true }
                return false
            }
            client.submitPIN(server.currentPIN)
            try await self.waitUntil("\(devName) synced initial seekable Spotify track") {
                client.connectionState.isConnected &&
                client.controlStripState.nowPlaying?.isSeekable == true
            }
            return (client, cliEnd)
        }
        defer {
            for (client, _) in companions {
                client.disconnect()
            }
        }

        // For each surface (iPhone, iPad, Watch), drag across 100 pixel increments and release once
        let targetFractions: [Double] = [0.50, 0.80, 0.20]
        for (index, (client, rawClientPipe)) in companions.enumerated() {
            let priorSeekCount = delegate.receivedSeeks.count
            let initialVolume = client.controlStripState.volume

            // Count raw wire frames sent from client -> server if we want, plus server delegate count
            for pixel in 0..<100 {
                let fraction = Double(pixel) / 100.0
                let preview = client.updateNowPlayingScrub(normalizedProgress: fraction)
                XCTAssertNotNil(preview)
                XCTAssertTrue(client.nowPlayingScrub.isScrubbing)
            }

            // Local preview follows the finger before lift
            let previewElapsed = client.nowPlayingScrub.effectiveElapsedSeconds(for: client.controlStripState.nowPlaying)
            let previewRow = NowPlayingProgressFormatter.rowDisplayContent(
                for: client.controlStripState.nowPlaying,
                overrideElapsedSeconds: previewElapsed
            )
            XCTAssertEqual(previewRow?.title, "Veridis Quo")
            XCTAssertEqual(previewRow?.progressText, "5:41 / 5:45")

            // Give the pipe a brief moment to prove ZERO seeks were sent while dragging
            try await Task.sleep(for: .milliseconds(35))
            XCTAssertEqual(
                delegate.receivedSeeks.count,
                priorSeekCount,
                "Dragging across 100 pixels must send 0 seek commands before finger lift"
            )

            // Lift finger once -> must encode and deliver EXACTLY ONE seek command
            let releaseFraction = targetFractions[index]
            let expectedSeconds = releaseFraction * 345.0
            let committed = client.commitNowPlayingScrub(normalizedProgress: releaseFraction)
            XCTAssertNotNil(committed)
            XCTAssertEqual(committed ?? -1, expectedSeconds, accuracy: 1e-6)
            XCTAssertFalse(client.nowPlayingScrub.isScrubbing)

            try await waitUntil("server received exactly 1 seek from \(client.platform)") {
                delegate.receivedSeeks.count == priorSeekCount + 1
            }
            XCTAssertEqual(delegate.receivedSeeks.last?.position ?? -1, expectedSeconds, accuracy: 1e-6)
            XCTAssertEqual(delegate.receivedLevels.count, 0, "Seeking must never mix in volume changes")
            XCTAssertEqual(client.controlStripState.volume, initialVolume, accuracy: 1e-9)

            // Unknown post-auth client frame stays non-fatal
            let unknownPostAuth = Data(#"{"futurePostAuthClientFrame":{"index":\#(index)}}"#.utf8)
            rawClientPipe.send(Self.wrapRawFrame(unknownPostAuth))
        }

        XCTAssertEqual(delegate.receivedSeeks.count, 3, "3 drag releases (Phone, iPad, Watch) -> 3 total seeks")

        // Verify post-auth unknown client frame is non-fatal (session stays alive and subsequent seek works)
        let (phone, _) = companions[0]
        // Switch Mac Now Playing to Safari (unsupported seek app) -> drag + release does nothing & sends 0 seeks
        var safariState = delegate.controlState
        safariState.nowPlaying = NowPlayingStatus(
            title: "Keynote Stream",
            appName: "Safari",
            isPlaying: true,
            elapsedSeconds: 83.0,
            durationSeconds: 244.0,
            bundleIdentifier: "com.apple.Safari"
        )
        delegate.controlState = safariState
        server.broadcastControlStripState(safariState)
        try await waitUntil("phone received Safari Now Playing") {
            phone.controlStripState.nowPlaying?.bundleIdentifier == "com.apple.Safari"
        }
        XCTAssertFalse(phone.controlStripState.nowPlaying?.isSeekable ?? true)
        XCTAssertEqual(phone.controlStripState.nowPlaying?.formattedProgressText, "1:23 / 4:04")
        XCTAssertNil(phone.updateNowPlayingScrub(normalizedProgress: 0.6))
        XCTAssertNil(phone.commitNowPlayingScrub(normalizedProgress: 0.6))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(delegate.receivedSeeks.count, 3, "Unsupported player drag/release must send 0 seeks")

        // Existing play/pause/next quick actions still reach Mac unchanged
        phone.performQuickAction(.mediaPlayPause)
        phone.performQuickAction(.mediaNext)
        try await waitUntil("server received mediaPlayPause and mediaNext") {
            delegate.receivedQuickActions == [.mediaPlayPause, .mediaNext]
        }
    }

    // MARK: - Helpers

    private static func wrapRawFrame(_ payload: Data) -> Data {
        var bigEndianLength = UInt32(payload.count).bigEndian
        var frame = Data(capacity: 4 + payload.count)
        withUnsafeBytes(of: &bigEndianLength) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    private func waitUntil(
        _ label: String,
        timeoutSeconds: TimeInterval = 2.5,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(12))
        }
        if condition() { return }
        throw TimeoutError(label: label)
    }
}

private extension Array {
    @MainActor
    func asyncMap<T>(_ transform: @MainActor (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self {
            results.append(try await transform(element))
        }
        return results
    }
}

@MainActor
private final class ScrubMockServerDelegate: MacServerEngineDelegate {
    weak var server: MacServerEngine?
    var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    var controlState: ControlStripState = ControlStripState()
    var receivedSeeks: [(deviceID: String, position: Double)] = []
    var receivedLevels: [(ControlLevelKind, Double)] = []
    var receivedQuickActions: [SystemQuickAction] = []

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { nil }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (false, nil) }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverCurrentOrcaStatus() -> OrcaTaskStatusSnapshot? { nil }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] { [:] }
    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {}

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        switch message {
        case .requestControlStripState:
            reply(.controlStripStateUpdated(controlState))
        case .seekNowPlaying(let positionSeconds):
            receivedSeeks.append((device.deviceID, positionSeconds))
            if var np = controlState.nowPlaying, let dur = np.durationSeconds, dur > 0 {
                np.elapsedSeconds = MacMediaSeekRouter.clampPosition(positionSeconds, durationSeconds: dur)
                controlState.nowPlaying = np
            }
            reply(.controlStripStateUpdated(controlState))
            server?.broadcastControlStripState(controlState, excludingDeviceID: device.deviceID)
        case .setControlLevel(let kind, let level):
            receivedLevels.append((kind, level))
        case .performQuickAction(let action):
            receivedQuickActions.append(action)
            reply(.actionFeedback(success: true, title: action.rawValue, detail: nil))
        default:
            break
        }
    }
}
