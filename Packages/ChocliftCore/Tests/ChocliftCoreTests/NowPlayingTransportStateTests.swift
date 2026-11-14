import XCTest
@testable import ChocliftCore

final class NowPlayingTransportStateTests: XCTestCase {
    func testSuccessfulPlayShowsPauseImmediately() {
        let paused = NowPlayingStatus(title: "Track", isPlaying: false)
        XCTAssertEqual(NowPlayingStatus.afterPlayPause(paused, success: true)?.isPlaying, true)
        XCTAssertEqual(NowPlayingStatus.afterPlayPause(nil, success: true)?.isPlaying, true)
    }

    func testSuccessfulPauseShowsPlayImmediately() {
        let playing = NowPlayingStatus(title: "Track", isPlaying: true)
        XCTAssertEqual(NowPlayingStatus.afterPlayPause(playing, success: true)?.isPlaying, false)
    }

    func testFailurePreservesState() {
        for playing in [false, true] {
            let previous = NowPlayingStatus(title: "Track", isPlaying: playing)
            XCTAssertEqual(NowPlayingStatus.afterPlayPause(previous, success: false), previous)
        }
        XCTAssertNil(NowPlayingStatus.afterPlayPause(nil, success: false))
    }

    func testStoppedNotificationWithTitleIsPausedTrack() {
        for state in ["stopped", "paused", ""] {
            let track = NowPlayingStatus.distributedPlayerUpdate(
                playerState: state, title: "Track", artist: "Artist",
                appName: "Spotify", bundleIdentifier: "com.spotify.client"
            )
            XCTAssertEqual(track?.title, "Track")
            XCTAssertEqual(track?.isPlaying, false)
            XCTAssertEqual(track?.hasActiveMedia, true)
        }
        XCTAssertNil(NowPlayingStatus.distributedPlayerUpdate(
            playerState: "stopped", title: "  ", artist: nil,
            appName: "Spotify", bundleIdentifier: "com.spotify.client"
        ))
    }

    func testPausedTrackSurvivesSnapshotAndReplacesOptimisticState() throws {
        var strip = ControlStripState()
        strip.nowPlaying = NowPlayingStatus.afterPlayPause(NowPlayingStatus(title: "Track"), success: true)
        XCTAssertEqual(strip.nowPlaying?.isPlaying, true)
        let authoritative = ControlStripState(nowPlaying: NowPlayingStatus(title: "Track", isPlaying: false))
        strip = try JSONDecoder().decode(ControlStripState.self, from: JSONEncoder().encode(authoritative))
        XCTAssertEqual(strip.nowPlaying?.title, "Track")
        XCTAssertEqual(strip.nowPlaying?.isPlaying, false)
        XCTAssertFalse(HoldToRepeatPolicy.supportsHoldToRepeat(.mediaPlayPause))
    }
}
