import Foundation
import XCTest
@testable import ChocliftCore

final class MediaActionPackTests: XCTestCase {
    func testMediaPackHasExactlyTenUniqueMediaIds() {
        let expectedIDs = [
            "media.seek_back_30",
            "media.seek_forward_30",
            "media.seek_back_60",
            "media.seek_forward_60",
            "media.restart_track",
            "media.volume_25",
            "media.volume_50",
            "media.volume_75",
            "media.volume_100",
            "media.toggle_repeat"
        ]

        let pack = CompanionActionCatalog.mediaPack
        XCTAssertEqual(pack.count, 10)
        XCTAssertEqual(pack.map(\.id), expectedIDs)
        XCTAssertEqual(Set(pack.map(\.id)).count, 10)
        XCTAssertTrue(pack.allSatisfy { $0.id.hasPrefix("media.") })
        XCTAssertFalse(pack.contains { $0.id.localizedCaseInsensitiveContains("like") })

        for action in pack {
            XCTAssertTrue(CompanionActionCatalog.isKnown(action.id))
            XCTAssertEqual(CompanionActionCatalog.action(id: action.id), action)
            XCTAssertFalse(action.title(in: .english).isEmpty)
            XCTAssertFalse(action.title(in: .chinese).isEmpty)
            XCTAssertFalse(action.sfSymbol.isEmpty)
        }
    }

    func testSeekTargetMathAndClamping() {
        XCTAssertEqual(
            MediaCompanionAction.seekBack30.seekTarget(positionSeconds: 40, durationSeconds: 100),
            .success(10)
        )
        XCTAssertEqual(
            MediaCompanionAction.seekForward30.seekTarget(positionSeconds: 40, durationSeconds: 100),
            .success(70)
        )
        XCTAssertEqual(
            MediaCompanionAction.seekBack60.seekTarget(positionSeconds: 10, durationSeconds: 100),
            .success(0)
        )
        XCTAssertEqual(
            MediaCompanionAction.seekForward60.seekTarget(positionSeconds: 80, durationSeconds: 100),
            .success(100)
        )
        XCTAssertEqual(
            MediaCompanionAction.restartTrack.seekTarget(positionSeconds: 40, durationSeconds: 100),
            .success(0)
        )

        var soughtTargets: [Double] = []
        let cases: [(id: String, position: Double, duration: Double, expected: Double)] = [
            ("media.seek_back_30", 40, 100, 10),
            ("media.seek_forward_30", 40, 100, 70),
            ("media.seek_back_60", 10, 100, 0),
            ("media.seek_forward_60", 80, 100, 100),
            ("media.restart_track", 40, 100, 0)
        ]
        for item in cases {
            let outcome = MediaCompanionAction.execute(
                id: item.id,
                language: .english,
                readSeekSession: { MediaCompanionSeekSession(positionSeconds: item.position, durationSeconds: item.duration) },
                performSeek: { target in
                    soughtTargets.append(target)
                    return (true, "Seeked to \(Int(target))s")
                },
                setVolume: { _ in XCTFail("Unexpected volume write"); return false },
                readRepeatSession: { MediaCompanionRepeatSession() },
                performSetRepeat: { _ in XCTFail("Unexpected repeat write"); return (false, "") }
            )
            XCTAssertTrue(outcome.success)
        }
        XCTAssertEqual(soughtTargets, [10, 70, 0, 100, 0])
    }

    func testMissingPositionAndMissingDurationFailClearly() {
        let seekActions: [MediaCompanionAction] = [
            .seekBack30,
            .seekForward30,
            .seekBack60,
            .seekForward60,
            .restartTrack
        ]

        for action in seekActions {
            XCTAssertEqual(
                action.seekTarget(positionSeconds: nil, durationSeconds: 100),
                .failure(.missingPosition)
            )
            XCTAssertEqual(
                action.seekTarget(positionSeconds: nil, durationSeconds: nil),
                .failure(.missingPosition)
            )
            XCTAssertEqual(
                action.seekTarget(positionSeconds: .nan, durationSeconds: 100),
                .failure(.missingPosition)
            )
            XCTAssertEqual(
                action.seekTarget(positionSeconds: -1, durationSeconds: 100),
                .failure(.missingPosition)
            )
            XCTAssertEqual(
                action.seekTarget(positionSeconds: 40, durationSeconds: nil),
                .failure(.missingDuration)
            )
            XCTAssertEqual(
                action.seekTarget(positionSeconds: 40, durationSeconds: 0),
                .failure(.missingDuration)
            )

            var didSeek = false
            let missingPosResult = MediaCompanionAction.execute(
                id: action.rawValue,
                language: .english,
                readSeekSession: { MediaCompanionSeekSession(positionSeconds: nil, durationSeconds: 100) },
                performSeek: { _ in didSeek = true; return (true, "") },
                setVolume: { _ in false },
                readRepeatSession: { MediaCompanionRepeatSession() },
                performSetRepeat: { _ in (false, "") }
            )
            XCTAssertFalse(missingPosResult.success)
            XCTAssertFalse(missingPosResult.message.isEmpty)
            XCTAssertFalse(didSeek)

            let missingDurResult = MediaCompanionAction.execute(
                id: action.rawValue,
                language: .chinese,
                readSeekSession: { MediaCompanionSeekSession(positionSeconds: 40, durationSeconds: nil) },
                performSeek: { _ in didSeek = true; return (true, "") },
                setVolume: { _ in false },
                readRepeatSession: { MediaCompanionRepeatSession() },
                performSetRepeat: { _ in (false, "") }
            )
            XCTAssertFalse(missingDurResult.success)
            XCTAssertFalse(missingDurResult.message.isEmpty)
            XCTAssertFalse(didSeek)
        }
    }

    func testVolumeLevelsAreExactAndReportPercent() {
        XCTAssertEqual(MediaCompanionAction.volume25.volumeLevel, 0.25)
        XCTAssertEqual(MediaCompanionAction.volume50.volumeLevel, 0.50)
        XCTAssertEqual(MediaCompanionAction.volume75.volumeLevel, 0.75)
        XCTAssertEqual(MediaCompanionAction.volume100.volumeLevel, 1.0)
        XCTAssertEqual(
            MediaCompanionAction.allCases.compactMap(\.volumeLevel),
            [0.25, 0.50, 0.75, 1.0]
        )

        var appliedLevels: [Double] = []
        let expected: [(id: String, level: Double, percentToken: String)] = [
            ("media.volume_25", 0.25, "25%"),
            ("media.volume_50", 0.50, "50%"),
            ("media.volume_75", 0.75, "75%"),
            ("media.volume_100", 1.0, "100%")
        ]
        for item in expected {
            let outcome = MediaCompanionAction.execute(
                id: item.id,
                language: .english,
                readSeekSession: { MediaCompanionSeekSession() },
                performSeek: { _ in (false, "") },
                setVolume: { level in
                    appliedLevels.append(level)
                    return true
                },
                readRepeatSession: { MediaCompanionRepeatSession() },
                performSetRepeat: { _ in (false, "") }
            )
            XCTAssertTrue(outcome.success)
            XCTAssertTrue(outcome.message.contains(item.percentToken))
        }
        XCTAssertEqual(appliedLevels, [0.25, 0.50, 0.75, 1.0])
    }

    func testRepeatCycleOrderAndUnreportedRepeatFailure() {
        XCTAssertEqual(MediaCompanionAction.repeatCycleOrder, [.off, .one, .all])
        XCTAssertEqual(MediaCompanionAction.nextRepeatMode(after: .off), .one)
        XCTAssertEqual(MediaCompanionAction.nextRepeatMode(after: .one), .all)
        XCTAssertEqual(MediaCompanionAction.nextRepeatMode(after: .all), .off)
        XCTAssertNil(MediaCompanionAction.nextRepeatMode(after: nil))

        XCTAssertEqual(MediaCompanionAction.nextRepeatMode(after: .off, for: .music), .one)
        XCTAssertEqual(MediaCompanionAction.nextRepeatMode(after: .one, for: .music), .all)
        XCTAssertEqual(MediaCompanionAction.nextRepeatMode(after: .all, for: .music), .off)
        XCTAssertNil(MediaCompanionAction.nextRepeatMode(after: nil, for: .music))

        var current: NowPlayingRepeatMode = .off
        var writtenModes: [NowPlayingRepeatMode] = []
        for _ in 0..<3 {
            let result = MediaCompanionAction.execute(
                id: "media.toggle_repeat",
                language: .english,
                readSeekSession: { MediaCompanionSeekSession() },
                performSeek: { _ in (false, "") },
                setVolume: { _ in false },
                readRepeatSession: { MediaCompanionRepeatSession(target: .music, currentRepeat: current) },
                performSetRepeat: { next in
                    writtenModes.append(next)
                    current = next
                    return (true, "Repeat \(next.rawValue)")
                }
            )
            XCTAssertTrue(result.success)
        }
        XCTAssertEqual(writtenModes, [.one, .all, .off])
        XCTAssertEqual(current, .off)

        var didWriteWhenUnknown = false
        let unknownRepeat = MediaCompanionAction.execute(
            id: "media.toggle_repeat",
            language: .english,
            readSeekSession: { MediaCompanionSeekSession() },
            performSeek: { _ in (false, "") },
            setVolume: { _ in false },
            readRepeatSession: { MediaCompanionRepeatSession(target: nil, currentRepeat: nil) },
            performSetRepeat: { _ in
                didWriteWhenUnknown = true
                return (true, "")
            }
        )
        XCTAssertFalse(unknownRepeat.success)
        XCTAssertFalse(unknownRepeat.message.isEmpty)
        XCTAssertFalse(didWriteWhenUnknown)
    }
}
