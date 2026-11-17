import XCTest
@testable import ChocliftCore

final class AppTimeTravelTests: XCTestCase {
    private struct PersistedEnvelope: Codable, Equatable {
        var schemaVersion: Int
        var timeTravel: AppTimeTravelBook
    }

    func testCapAtTwentyIncludingPinsAndNeverDropsPinnedApps() {
        var book = AppTimeTravelBook()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        for idx in 0..<25 {
            let recorded = book.recordActivation(
                bundleID: "com.example.app\(idx)",
                appName: "App \(idx)",
                at: baseDate.addingTimeInterval(TimeInterval(idx * 10))
            )
            XCTAssertTrue(recorded)
        }

        XCTAssertEqual(book.entries.count, 20)
        XCTAssertEqual(book.entries.first?.bundleID, "com.example.app24")
        XCTAssertEqual(book.entries.last?.bundleID, "com.example.app5")
        XCTAssertFalse(book.entries.contains { $0.bundleID == "com.example.app0" })
        XCTAssertFalse(book.entries.contains { $0.bundleID == "com.example.app4" })

        // Re-activating the oldest kept recent moves it to most-recent without dropping another app.
        book.recordActivation(
            bundleID: "com.example.app5",
            appName: "App 5",
            at: baseDate.addingTimeInterval(1_000)
        )
        XCTAssertEqual(book.entries.count, 20)
        XCTAssertEqual(book.entries.first?.bundleID, "com.example.app5")

        // With 5 pinned apps (even with ancient timestamps), only 15 recents are kept and pins are never dropped.
        var pinnedBook = AppTimeTravelBook()
        for pinIdx in 0..<5 {
            let oldDate = baseDate.addingTimeInterval(TimeInterval(pinIdx))
            pinnedBook.recordActivation(
                bundleID: "com.pinned.app\(pinIdx)",
                appName: "Pinned \(pinIdx)",
                at: oldDate
            )
            XCTAssertEqual(pinnedBook.pin("com.pinned.app\(pinIdx)"), .success(pinIdx))
        }

        for recentIdx in 0..<20 {
            pinnedBook.recordActivation(
                bundleID: "com.recent.app\(recentIdx)",
                appName: "Recent \(recentIdx)",
                at: baseDate.addingTimeInterval(TimeInterval(10_000 + recentIdx * 10))
            )
        }

        XCTAssertEqual(pinnedBook.entries.count, 20)
        XCTAssertEqual(pinnedBook.pinnedEntries.count, 5)
        XCTAssertEqual(pinnedBook.unpinnedEntries.count, 15)
        XCTAssertEqual(
            pinnedBook.pinnedEntries.map(\.bundleID),
            (0..<5).map { "com.pinned.app\($0)" }
        )
        XCTAssertEqual(pinnedBook.unpinnedEntries.first?.bundleID, "com.recent.app19")
        XCTAssertEqual(pinnedBook.unpinnedEntries.last?.bundleID, "com.recent.app5")
        for droppedIdx in 0..<5 {
            XCTAssertNil(pinnedBook.entry(for: "com.recent.app\(droppedIdx)"))
        }
    }

    func testPinAssignsNextFreeIndexAndFailsWithPinLimitKey() {
        var book = AppTimeTravelBook()
        let baseDate = Date(timeIntervalSince1970: 1_700_010_000)

        for idx in 0..<6 {
            book.recordActivation(
                bundleID: "com.example.pin\(idx)",
                appName: "Pin \(idx)",
                at: baseDate.addingTimeInterval(TimeInterval(idx * 10))
            )
        }

        for expectedPinIndex in 0..<5 {
            let result = book.pin("com.example.pin\(expectedPinIndex)")
            XCTAssertEqual(result, .success(expectedPinIndex))
            XCTAssertEqual(book.entry(for: "com.example.pin\(expectedPinIndex)")?.pinnedIndex, expectedPinIndex)
        }

        XCTAssertEqual(book.pinnedCount, 5)
        XCTAssertFalse(book.canPinMore)
        XCTAssertNil(book.nextFreePinIndex)

        let sixthResult = book.pin(bundleID: "com.example.pin5")
        switch sixthResult {
        case .success(let index):
            XCTFail("Expected pin_limit failure when 5 apps are pinned, got index \(index)")
        case .failure(let error):
            XCTAssertEqual(error, .pinLimit)
            XCTAssertEqual(error.messageKey, "pin_limit")
            XCTAssertEqual(error.rawValue, AppTimeTravelBook.pinLimitMessageKey)
            XCTAssertEqual(error.localizedMessage(in: .chinese), "最多只能固定 5 个 App")
            XCTAssertEqual(error.localizedMessage(in: .english), "Cannot pin more than 5 apps")
        }
        XCTAssertNil(book.entry(for: "com.example.pin5")?.pinnedIndex)

        // Re-pinning an already-pinned app is idempotent and returns its existing slot.
        XCTAssertEqual(book.pin("com.example.pin2"), .success(2))

        // Unpinning slots 1 and 3 frees those exact indices; subsequent pins refill 1 then 3.
        XCTAssertTrue(book.unpin("com.example.pin1"))
        XCTAssertTrue(book.unpin(bundleID: "com.example.pin3"))
        XCTAssertEqual(book.pinnedEntries.compactMap(\.pinnedIndex), [0, 2, 4])
        XCTAssertEqual(book.nextFreePinIndex, 1)

        XCTAssertEqual(book.pin("com.example.pin5"), .success(1))
        XCTAssertEqual(book.nextFreePinIndex, 3)
        XCTAssertEqual(book.pin("com.example.brandnew", appName: "Brand New"), .success(3))
        XCTAssertEqual(
            book.pinnedEntries.map { ($0.bundleID, $0.pinnedIndex ?? -1) }.map { "\($0.0):\($0.1)" },
            [
                "com.example.pin0:0",
                "com.example.pin5:1",
                "com.example.pin2:2",
                "com.example.brandnew:3",
                "com.example.pin4:4"
            ]
        )
    }

    func testPinnedAppsDoNotMoveWhenActivated() {
        var book = AppTimeTravelBook()
        let t0 = Date(timeIntervalSince1970: 1_700_020_000)

        book.recordActivation("com.apple.Safari", appName: "Safari", at: t0)
        book.recordActivation("com.apple.Terminal", appName: "Terminal", at: t0.addingTimeInterval(10))
        book.recordActivation("com.apple.dt.Xcode", appName: "Xcode", at: t0.addingTimeInterval(20))
        book.recordActivation("com.apple.Notes", appName: "Notes", at: t0.addingTimeInterval(30))
        book.recordActivation("com.apple.Music", appName: "Music", at: t0.addingTimeInterval(40))

        XCTAssertEqual(book.pin("com.apple.Safari"), .success(0))
        XCTAssertEqual(book.pin("com.apple.Terminal"), .success(1))
        XCTAssertEqual(book.pin("com.apple.dt.Xcode"), .success(2))

        let expectedOrderBefore = [
            "com.apple.Safari",
            "com.apple.Terminal",
            "com.apple.dt.Xcode",
            "com.apple.Music",
            "com.apple.Notes"
        ]
        XCTAssertEqual(book.entries.map(\.bundleID), expectedOrderBefore)

        // Activating pinned apps must not reorder them or alter their pinned indices.
        book.recordActivation("com.apple.dt.Xcode", appName: "Xcode", at: t0.addingTimeInterval(100))
        book.recordActivation("com.apple.Terminal", appName: "Terminal", at: t0.addingTimeInterval(200))

        XCTAssertEqual(book.entries.map(\.bundleID), expectedOrderBefore)
        XCTAssertEqual(book.entry(for: "com.apple.Safari")?.pinnedIndex, 0)
        XCTAssertEqual(book.entry(for: "com.apple.Terminal")?.pinnedIndex, 1)
        XCTAssertEqual(book.entry(for: "com.apple.dt.Xcode")?.pinnedIndex, 2)

        // Activating an unpinned app moves it ahead of other unpinned apps, but after all pinned apps.
        book.recordActivation("com.apple.Notes", appName: "Notes", at: t0.addingTimeInterval(300))
        XCTAssertEqual(
            book.entries.map(\.bundleID),
            [
                "com.apple.Safari",
                "com.apple.Terminal",
                "com.apple.dt.Xcode",
                "com.apple.Notes",
                "com.apple.Music"
            ]
        )
    }

    func testUnpinReturnsAppToRecentOrderByLastUsedAtAndClearHistoryRemovesAll() {
        var book = AppTimeTravelBook()
        let base = Date(timeIntervalSince1970: 1_700_030_000)

        book.recordActivation(bundleID: "com.app.alpha", appName: "Alpha", lastUsedAt: base.addingTimeInterval(100))
        book.recordActivation(bundleID: "com.app.beta", appName: "Beta", lastUsedAt: base.addingTimeInterval(200))
        book.recordActivation(bundleID: "com.app.gamma", appName: "Gamma", lastUsedAt: base.addingTimeInterval(300))
        book.recordActivation(bundleID: "com.app.delta", appName: "Delta", lastUsedAt: base.addingTimeInterval(400))

        XCTAssertEqual(
            book.entries.map(\.bundleID),
            ["com.app.delta", "com.app.gamma", "com.app.beta", "com.app.alpha"]
        )

        XCTAssertEqual(book.pin("com.app.beta"), .success(0))
        XCTAssertEqual(book.pin("com.app.alpha"), .success(1))
        XCTAssertEqual(
            book.entries.map(\.bundleID),
            ["com.app.beta", "com.app.alpha", "com.app.delta", "com.app.gamma"]
        )

        // Beta was never used again while pinned (lastUsedAt = +200), so unpinning returns it after Gamma (+300).
        XCTAssertTrue(book.unpin("com.app.beta"))
        XCTAssertNil(book.entry(for: "com.app.beta")?.pinnedIndex)
        XCTAssertEqual(
            book.entries.map(\.bundleID),
            ["com.app.alpha", "com.app.delta", "com.app.gamma", "com.app.beta"]
        )

        // Alpha is activated at +350 while still pinned: stays in its pinned slot until unpinned,
        // then lands between Delta (+400) and Gamma (+300).
        book.recordActivation("com.app.alpha", appName: "Alpha", at: base.addingTimeInterval(350))
        XCTAssertEqual(book.entries.first?.bundleID, "com.app.alpha")
        XCTAssertEqual(book.entry(for: "com.app.alpha")?.pinnedIndex, 1)

        XCTAssertTrue(book.unpin("com.app.alpha"))
        XCTAssertEqual(
            book.entries.map(\.bundleID),
            ["com.app.delta", "com.app.alpha", "com.app.gamma", "com.app.beta"]
        )

        // Unpinning an already-unpinned or unknown app returns false.
        XCTAssertFalse(book.unpin("com.app.alpha"))
        XCTAssertFalse(book.unpin("com.app.unknown"))

        // Re-pin one item and verify clearHistory removes both recents and pins.
        XCTAssertEqual(book.pin("com.app.gamma"), .success(0))
        XCTAssertFalse(book.isEmpty)
        XCTAssertEqual(book.pinnedCount, 1)

        book.clearHistory()
        XCTAssertTrue(book.isEmpty)
        XCTAssertEqual(book.entries, [])
        XCTAssertEqual(book.pinnedCount, 0)
        XCTAssertEqual(book.nextFreePinIndex, 0)
    }

    func testRejectsChocliftAndBlankBundleIdentifiers() {
        let rejectedBundleIDs = [
            "",
            "   ",
            "com.choclift",
            "com.choclift.mac",
            "com.choclift.ios",
            "com.choclift.ios.watchkitapp",
            "com.choclift.app-setapp",
            "  COM.CHOCLIFT.APP-SETAPP  "
        ]

        var book = AppTimeTravelBook()
        for bundleID in rejectedBundleIDs {
            XCTAssertFalse(book.recordActivation(bundleID: bundleID, appName: "Choclift"))
            XCTAssertEqual(book.pin(bundleID), .failure(.rejectedBundleID))
            XCTAssertFalse(book.unpin(bundleID))
        }
        XCTAssertTrue(book.isEmpty)

        // Direct initialization also strips any com.choclift.* entries.
        let seeded = AppTimeTravelBook(entries: [
            AppTimeTravelEntry(bundleID: "com.choclift.app-setapp", appName: "choclift", pinnedIndex: 0),
            AppTimeTravelEntry(bundleID: "com.choclift.mac", appName: "Choclift Mac"),
            AppTimeTravelEntry(bundleID: "com.apple.Safari", appName: "Safari", pinnedIndex: 0),
            AppTimeTravelEntry(bundleID: "com.chocliftlike.thirdparty", appName: "ThirdParty")
        ])
        XCTAssertEqual(seeded.entries.map(\.bundleID), ["com.apple.Safari", "com.chocliftlike.thirdparty"])
    }

    func testCodableRoundTripAndMissingBookDecodesEmpty() throws {
        let base = Date(timeIntervalSince1970: 1_700_040_000)
        var book = AppTimeTravelBook()
        book.recordActivation("com.apple.Safari", appName: "Safari", at: base.addingTimeInterval(10))
        book.recordActivation("com.apple.Notes", appName: "Notes", at: base.addingTimeInterval(20))
        book.recordActivation("com.apple.Terminal", appName: "Terminal", at: base.addingTimeInterval(30))
        XCTAssertEqual(book.pin("com.apple.Notes"), .success(0))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try encoder.encode(book)
        let decoded = try decoder.decode(AppTimeTravelBook.self, from: encoded)
        XCTAssertEqual(decoded, book)

        // Missing book key in legacy container JSON decodes to an empty book.
        let legacyMissingKeyJSON = Data(#"{"schemaVersion":1}"#.utf8)
        let decodedMissing = try decoder.decode(PersistedEnvelope.self, from: legacyMissingKeyJSON)
        XCTAssertEqual(decodedMissing.schemaVersion, 1)
        XCTAssertEqual(decodedMissing.timeTravel, .empty)
        XCTAssertTrue(decodedMissing.timeTravel.isEmpty)

        // Null book key in container JSON decodes to an empty book.
        let nullBookJSON = Data(#"{"schemaVersion":2,"timeTravel":null}"#.utf8)
        let decodedNull = try decoder.decode(PersistedEnvelope.self, from: nullBookJSON)
        XCTAssertEqual(decodedNull.timeTravel, .empty)

        // Empty JSON object or nil/empty Data decodes to an empty book.
        XCTAssertEqual(try decoder.decode(AppTimeTravelBook.self, from: Data("{}".utf8)), .empty)
        XCTAssertEqual(try AppTimeTravelBook.decode(from: nil), .empty)
        XCTAssertEqual(try AppTimeTravelBook.decode(from: Data()), .empty)
        XCTAssertEqual(try AppTimeTravelBook.decode(from: Data("   ".utf8)), .empty)

        // Dirty JSON sanitizes choclift entries, excess/out-of-range pins, and caps total at 20.
        var dirtyEntries: [[String: Any]] = [
            ["bundleID": "com.choclift.app-setapp", "appName": "choclift", "lastUsedAt": 500, "pinnedIndex": 0]
        ]
        for idx in 0..<7 {
            dirtyEntries.append([
                "bundleID": "com.dirty.pin\(idx)",
                "appName": "Dirty Pin \(idx)",
                "lastUsedAt": Double(100 + idx),
                "pinnedIndex": idx // 5 and 6 are out-of-range and become unpinned
            ])
        }
        for idx in 0..<20 {
            dirtyEntries.append([
                "bundleID": "com.dirty.recent\(idx)",
                "appName": "Dirty Recent \(idx)",
                "lastUsedAt": Double(1_000 + idx)
            ])
        }
        let dirtyData = try JSONSerialization.data(withJSONObject: ["entries": dirtyEntries])
        let sanitizedBook = try decoder.decode(AppTimeTravelBook.self, from: dirtyData)
        XCTAssertEqual(sanitizedBook.entries.count, 20)
        XCTAssertEqual(sanitizedBook.pinnedCount, 5)
        XCTAssertEqual(sanitizedBook.unpinnedEntries.count, 15)
        XCTAssertFalse(sanitizedBook.entries.contains { AppTimeTravelBook.isChocliftBundleIdentifier($0.bundleID) })
    }
}
