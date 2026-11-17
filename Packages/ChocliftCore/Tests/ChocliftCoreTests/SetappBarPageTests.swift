import Foundation
import XCTest
@testable import ChocliftCore

final class SetappBarPageTests: XCTestCase {
    private struct SynthesizedBookEnvelope: Codable, Equatable {
        var schemaVersion: Int
        var macName: String
        var book: SetappBarBook
    }

    private struct ExplicitDecodeIfPresentEnvelope: Codable, Equatable {
        var schemaVersion: Int
        var book: SetappBarBook

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case book
        }

        init(schemaVersion: Int, book: SetappBarBook) {
            self.schemaVersion = schemaVersion
            self.book = book
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            self.book = try container.decodeIfPresent(SetappBarBook.self, forKey: .book) ?? SetappBarBook()
        }
    }

    func testEightPagesAlways() {
        XCTAssertEqual(SetappBarPageCount, 8)
        XCTAssertEqual(SetappBarBook.pageCount, 8)
        XCTAssertEqual(SetappBarPage.pageCount, 8)

        let defaultBook = SetappBarBook()
        assertIsEightEmptyOneTilePages(defaultBook)
        XCTAssertEqual(Set(defaultBook.pages.map(\.id)).count, 8)

        let fromEmpty = SetappBarBook(pages: [])
        assertIsEightEmptyOneTilePages(fromEmpty)

        let safari = try! XCTUnwrap(SetappBarSlot.app(bundleID: "com.apple.Safari", displayName: "Safari"))
        let notes = try! XCTUnwrap(SetappBarSlot.app(bundleID: "com.apple.Notes", displayName: "Notes"))
        let customTwoPages = [
            SetappBarPage(index: 5, layout: .two, slots: [safari, notes]),
            SetappBarPage(index: 7, layout: .four, slots: [notes])
        ]
        let paddedBook = SetappBarBook(pages: customTwoPages)
        XCTAssertEqual(paddedBook.pages.count, 8)
        XCTAssertEqual(paddedBook.pages.map(\.index), Array(0..<8))
        XCTAssertEqual(paddedBook.pages[0].layout, .two)
        XCTAssertEqual(paddedBook.pages[0].slots, [safari, notes])
        XCTAssertEqual(paddedBook.pages[1].layout, .four)
        XCTAssertEqual(paddedBook.pages[1].slots.count, 4)
        XCTAssertEqual(paddedBook.pages[1].slots[0], notes)
        XCTAssertTrue(paddedBook.pages[1].slots.dropFirst().allSatisfy(\.isEmpty))
        for index in 2..<8 {
            XCTAssertEqual(paddedBook.pages[index].layout, .one)
            XCTAssertEqual(paddedBook.pages[index].slots.count, 1)
            XCTAssertTrue(paddedBook.pages[index].slots[0].isEmpty)
        }

        let twelvePages = (0..<12).map { idx in
            SetappBarPage(index: idx, layout: .three)
        }
        var truncatedBook = SetappBarBook(pages: twelvePages)
        XCTAssertEqual(truncatedBook.pages.count, 8)
        XCTAssertEqual(truncatedBook.pages.map(\.index), Array(0..<8))
        XCTAssertEqual(truncatedBook.pages.map(\.id), Array(twelvePages.prefix(8).map(\.id)))

        truncatedBook.pages = []
        assertIsEightEmptyOneTilePages(truncatedBook)

        truncatedBook.pages = twelvePages
        XCTAssertEqual(truncatedBook.pages.count, 8)
        XCTAssertEqual(truncatedBook.pages.map(\.index), Array(0..<8))

        XCTAssertEqual(SetappBarPage(index: -3).index, 0)
        XCTAssertEqual(SetappBarPage(index: 99).index, 7)
    }

    func testLayoutSlotCountsAndSlotPayloads() throws {
        XCTAssertEqual(SetappBarTileLayout.allCases, [.one, .two, .three, .four])
        XCTAssertEqual(SetappBarTileLayout.one.slotCount, 1)
        XCTAssertEqual(SetappBarTileLayout.two.slotCount, 2)
        XCTAssertEqual(SetappBarTileLayout.three.slotCount, 3)
        XCTAssertEqual(SetappBarTileLayout.four.slotCount, 4)
        XCTAssertEqual(SetappBarTileLayout.one.next, .two)
        XCTAssertEqual(SetappBarTileLayout.two.next, .three)
        XCTAssertEqual(SetappBarTileLayout.three.next, .four)
        XCTAssertEqual(SetappBarTileLayout.four.next, .one)
        XCTAssertNil(SetappBarTileLayout(slotCount: 0))
        XCTAssertNil(SetappBarTileLayout(slotCount: 5))

        let appSlot = try XCTUnwrap(
            SetappBarSlot.app(bundleID: "com.apple.Safari", displayName: "Safari")
        )
        let shortcutSlot = try XCTUnwrap(
            SetappBarSlot.shortcut(shortcutName: "Focus Work", emoji: "⚡️", displayName: "Focus")
        )
        let websiteURL = try XCTUnwrap(URL(string: "https://apple.com"))
        let websiteSlot = SetappBarSlot.website(url: websiteURL, displayName: "Apple")
        let emojiSlot = try XCTUnwrap(
            SetappBarSlot.emoji("🍫", displayName: "Choc")
        )
        let emptySlot = SetappBarSlot.empty

        XCTAssertEqual(appSlot.kind, .app)
        XCTAssertEqual(appSlot.bundleID, "com.apple.Safari")
        XCTAssertEqual(appSlot.displayName, "Safari")
        XCTAssertNil(appSlot.shortcutName)
        XCTAssertNil(appSlot.url)
        XCTAssertNil(appSlot.emoji)

        XCTAssertEqual(shortcutSlot.kind, .shortcut)
        XCTAssertEqual(shortcutSlot.shortcutName, "Focus Work")
        XCTAssertEqual(shortcutSlot.emoji, "⚡️")
        XCTAssertEqual(shortcutSlot.displayName, "Focus")
        XCTAssertNil(shortcutSlot.bundleID)
        XCTAssertNil(shortcutSlot.url)

        XCTAssertEqual(websiteSlot.kind, .website)
        XCTAssertEqual(websiteSlot.url, websiteURL)
        XCTAssertEqual(websiteSlot.displayName, "Apple")
        XCTAssertNil(websiteSlot.bundleID)
        XCTAssertNil(websiteSlot.shortcutName)
        XCTAssertNil(websiteSlot.emoji)

        XCTAssertEqual(emojiSlot.kind, .emoji)
        XCTAssertEqual(emojiSlot.emoji, "🍫")
        XCTAssertEqual(emojiSlot.emojiCharacter, Character("🍫"))
        XCTAssertEqual(emojiSlot.displayName, "Choc")
        XCTAssertNil(emojiSlot.bundleID)
        XCTAssertNil(emojiSlot.shortcutName)
        XCTAssertNil(emojiSlot.url)

        XCTAssertEqual(emptySlot.kind, .empty)
        XCTAssertFalse(emptySlot.hasPayload)
        XCTAssertNil(emptySlot.bundleID)
        XCTAssertNil(emptySlot.shortcutName)
        XCTAssertNil(emptySlot.url)
        XCTAssertNil(emptySlot.emoji)
        XCTAssertNil(emptySlot.displayName)

        let strippedEmpty = try XCTUnwrap(
            SetappBarSlot(
                kind: .empty,
                bundleID: "com.apple.Safari",
                shortcutName: "Ignored",
                url: websiteURL,
                emoji: "🍫",
                displayName: "Ignored"
            )
        )
        XCTAssertEqual(strippedEmpty.kind, .empty)
        XCTAssertFalse(strippedEmpty.hasPayload)

        for layout in SetappBarTileLayout.allCases {
            let underfilled = SetappBarPage(index: 0, layout: layout, slots: [])
            XCTAssertEqual(underfilled.slots.count, layout.slotCount)
            XCTAssertTrue(underfilled.slots.allSatisfy(\.isEmpty))

            let overfilled = SetappBarPage(
                index: 0,
                layout: layout,
                slots: [appSlot, shortcutSlot, websiteSlot, emojiSlot, SetappBarSlot.empty]
            )
            XCTAssertEqual(overfilled.slots.count, layout.slotCount)
        }

        var mutablePage = SetappBarPage(
            index: 0,
            layout: .two,
            slots: [appSlot, shortcutSlot, websiteSlot, emojiSlot]
        )
        XCTAssertEqual(mutablePage.slots, [appSlot, shortcutSlot])

        mutablePage.slots = [appSlot, shortcutSlot, websiteSlot]
        mutablePage.sanitize()
        XCTAssertEqual(mutablePage.slots, [appSlot, shortcutSlot])

        mutablePage.slots = [appSlot]
        mutablePage.sanitize()
        XCTAssertEqual(mutablePage.slots.count, 2)
        XCTAssertEqual(mutablePage.slots[0], appSlot)
        XCTAssertTrue(mutablePage.slots[1].isEmpty)

        mutablePage.layout = .four
        XCTAssertEqual(mutablePage.slots.count, 4)
        XCTAssertEqual(mutablePage.slots[0], appSlot)
        XCTAssertTrue(mutablePage.slots[1].isEmpty)
        XCTAssertTrue(mutablePage.slots[2].isEmpty)
        XCTAssertTrue(mutablePage.slots[3].isEmpty)

        mutablePage.layout = .one
        XCTAssertEqual(mutablePage.slots, [appSlot])
    }

    func testMovePageAndMoveSlotAndSetSlot() throws {
        var book = SetappBarBook()
        let initialPageIDs = book.pages.map(\.id)

        XCTAssertTrue(book.movePage(from: 1, to: 5))
        XCTAssertEqual(book.pages.count, 8)
        XCTAssertEqual(book.pages.map(\.index), Array(0..<8))
        XCTAssertEqual(
            book.pages.map(\.id),
            [
                initialPageIDs[0],
                initialPageIDs[2],
                initialPageIDs[3],
                initialPageIDs[4],
                initialPageIDs[5],
                initialPageIDs[1],
                initialPageIDs[6],
                initialPageIDs[7]
            ]
        )

        XCTAssertTrue(book.movePage(from: 5, to: 1))
        XCTAssertEqual(book.pages.map(\.id), initialPageIDs)
        XCTAssertEqual(book.pages.map(\.index), Array(0..<8))

        XCTAssertFalse(book.movePage(from: -1, to: 2))
        XCTAssertFalse(book.movePage(from: 2, to: 8))
        XCTAssertEqual(book.pages.map(\.id), initialPageIDs)

        let slotA = try XCTUnwrap(SetappBarSlot.app(bundleID: "com.apple.Safari", displayName: "Safari"))
        let slotB = try XCTUnwrap(SetappBarSlot.shortcut(shortcutName: "Morning", displayName: "Morning"))
        let slotC = try XCTUnwrap(SetappBarSlot.website(urlString: "https://example.com", displayName: "Example"))
        let slotD = try XCTUnwrap(SetappBarSlot.emoji("🔥", displayName: "Fire"))

        XCTAssertTrue(book.setLayout(.four, forPage: 3))
        XCTAssertTrue(book.setSlot(slotA, page: 3, slot: 0))
        XCTAssertTrue(book.setSlot(slotB, page: 3, slot: 1))
        XCTAssertTrue(book.setSlot(slotC, page: 3, slot: 2))
        XCTAssertTrue(book.setSlot(slotD, page: 3, slot: 3))
        XCTAssertEqual(book.pages[3].slots, [slotA, slotB, slotC, slotD])

        XCTAssertFalse(book.setSlot(slotA, page: 3, slot: 4))
        XCTAssertFalse(book.setSlot(slotA, page: 8, slot: 0))

        XCTAssertTrue(book.moveSlot(page: 3, from: 0, to: 2))
        XCTAssertEqual(book.pages[3].slots, [slotB, slotC, slotA, slotD])

        XCTAssertTrue(book.moveSlot(page: 3, from: 3, to: 0))
        XCTAssertEqual(book.pages[3].slots, [slotD, slotB, slotC, slotA])

        XCTAssertFalse(book.moveSlot(page: 3, from: 0, to: 4))
        XCTAssertFalse(book.moveSlot(page: -1, from: 0, to: 1))
        XCTAssertEqual(book.pages[3].slots, [slotD, slotB, slotC, slotA])
    }

    func testClearPageEmptiesSlotsAndKeepsLayout() throws {
        let safari = try XCTUnwrap(SetappBarSlot.app(bundleID: "com.apple.Safari", displayName: "Safari"))
        let xcode = try XCTUnwrap(SetappBarSlot.app(bundleID: "com.apple.dt.Xcode", displayName: "Xcode"))
        let terminal = try XCTUnwrap(SetappBarSlot.app(bundleID: "com.apple.Terminal", displayName: "Terminal"))

        var book = SetappBarBook()
        XCTAssertTrue(book.setLayout(.three, forPage: 2))
        XCTAssertTrue(book.setSlot(safari, page: 2, slot: 0))
        XCTAssertTrue(book.setSlot(xcode, page: 2, slot: 1))
        XCTAssertTrue(book.setSlot(terminal, page: 2, slot: 2))
        XCTAssertTrue(book.setSlot(safari, page: 4, slot: 0))

        let page2ID = book.pages[2].id
        XCTAssertTrue(book.clearPage(index: 2))

        XCTAssertEqual(book.pages[2].id, page2ID)
        XCTAssertEqual(book.pages[2].index, 2)
        XCTAssertEqual(book.pages[2].layout, .three)
        XCTAssertEqual(book.pages[2].slots.count, 3)
        XCTAssertTrue(book.pages[2].slots.allSatisfy { $0.isEmpty && !$0.hasPayload })
        XCTAssertEqual(book.pages[4].slots[0], safari)

        XCTAssertFalse(book.clearPage(index: -1))
        XCTAssertFalse(book.clearPage(index: 8))
    }

    func testChocliftBundleRejected() throws {
        let rejectedBundles = [
            "com.choclift",
            "com.choclift.mac",
            "com.choclift.ios",
            "com.choclift.ios.watchkitapp",
            "com.choclift.app-setapp",
            "  COM.CHOCLIFT.App-Setapp \n"
        ]
        for bundleID in rejectedBundles {
            XCTAssertTrue(SetappBarSlot.isChocliftBundleID(bundleID), "Expected \(bundleID) to be rejected")
            XCTAssertNil(SetappBarSlot.app(bundleID: bundleID, displayName: "choclift"))
            XCTAssertNil(SetappBarSlot(kind: .app, bundleID: bundleID, displayName: "choclift"))
        }

        XCTAssertFalse(SetappBarSlot.isChocliftBundleID("com.apple.Safari"))
        XCTAssertFalse(SetappBarSlot.isChocliftBundleID("com.chocliftlike.other"))
        XCTAssertNotNil(SetappBarSlot.app(bundleID: "com.chocliftlike.other", displayName: "Other"))

        let safari = try XCTUnwrap(SetappBarSlot.app(bundleID: "com.apple.Safari", displayName: "Safari"))
        var book = SetappBarBook()
        XCTAssertTrue(book.setSlot(safari, page: 0, slot: 0))
        XCTAssertFalse(
            book.setSlot(
                SetappBarSlot.app(bundleID: "com.choclift.app-setapp", displayName: "choclift"),
                page: 0,
                slot: 0
            )
        )
        XCTAssertEqual(book.pages[0].slots[0], safari)

        let tamperedSlotJSON = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "kind": "app",
          "bundleID": "com.choclift.app-setapp",
          "displayName": "choclift"
        }
        """
        let decodedSlot = try JSONDecoder().decode(SetappBarSlot.self, from: Data(tamperedSlotJSON.utf8))
        XCTAssertEqual(decodedSlot.id, UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(decodedSlot.kind, .empty)
        XCTAssertFalse(decodedSlot.hasPayload)
        XCTAssertNil(decodedSlot.bundleID)
        XCTAssertNil(decodedSlot.displayName)
    }

    func testOldJSONWithoutBookDecodesAndPopulatedBookRoundTrips() throws {
        let legacyJSON = Data(#"{"schemaVersion": 1, "macName": "Studio Mac"}"#.utf8)
        let decodedSynthesized = try JSONDecoder().decode(SynthesizedBookEnvelope.self, from: legacyJSON)
        XCTAssertEqual(decodedSynthesized.schemaVersion, 1)
        XCTAssertEqual(decodedSynthesized.macName, "Studio Mac")
        assertIsEightEmptyOneTilePages(decodedSynthesized.book)

        let nullBookJSON = Data(#"{"schemaVersion": 2, "macName": "Studio Mac", "book": null}"#.utf8)
        let decodedNullBook = try JSONDecoder().decode(SynthesizedBookEnvelope.self, from: nullBookJSON)
        assertIsEightEmptyOneTilePages(decodedNullBook.book)

        let decodedExplicit = try JSONDecoder().decode(ExplicitDecodeIfPresentEnvelope.self, from: legacyJSON)
        assertIsEightEmptyOneTilePages(decodedExplicit.book)

        let emptyObjectBook = try JSONDecoder().decode(SetappBarBook.self, from: Data("{}".utf8))
        assertIsEightEmptyOneTilePages(emptyObjectBook)

        let directLegacyBook = try JSONDecoder().decode(SetappBarBook.self, from: legacyJSON)
        assertIsEightEmptyOneTilePages(directLegacyBook)

        let topLevelNullBook = try JSONDecoder().decode(SetappBarBook.self, from: Data("null".utf8))
        assertIsEightEmptyOneTilePages(topLevelNullBook)

        var book = SetappBarBook()
        XCTAssertTrue(book.setLayout(.four, forPage: 0))
        let safari = try XCTUnwrap(SetappBarSlot.app(bundleID: "com.apple.Safari", displayName: "Safari"))
        let shortcut = try XCTUnwrap(SetappBarSlot.shortcut(shortcutName: "Ship It", emoji: "🚀", displayName: "Ship"))
        let website = try XCTUnwrap(SetappBarSlot.website(urlString: "https://developer.apple.com", displayName: "Docs"))
        let emoji = try XCTUnwrap(SetappBarSlot.emoji("🍫", displayName: "Cocoa"))
        XCTAssertTrue(book.setSlot(safari, page: 0, slot: 0))
        XCTAssertTrue(book.setSlot(shortcut, page: 0, slot: 1))
        XCTAssertTrue(book.setSlot(website, page: 0, slot: 2))
        XCTAssertTrue(book.setSlot(emoji, page: 0, slot: 3))
        XCTAssertTrue(book.setLayout(.two, forPage: 1))

        let envelope = SynthesizedBookEnvelope(schemaVersion: 3, macName: "MacBook Pro", book: book)
        let encoded = try JSONEncoder().encode(envelope)
        let roundTripped = try JSONDecoder().decode(SynthesizedBookEnvelope.self, from: encoded)
        XCTAssertEqual(roundTripped, envelope)

        let emptyEncoded = try JSONEncoder().encode(SetappBarSlot.empty)
        let rawEmptyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyEncoded) as? [String: Any])
        XCTAssertEqual(Set(rawEmptyObject.keys), ["id", "kind"])
        XCTAssertEqual(rawEmptyObject["kind"] as? String, "empty")
    }

    private func assertIsEightEmptyOneTilePages(
        _ book: SetappBarBook,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(book.pages.count, 8, file: file, line: line)
        XCTAssertEqual(book.pages.map(\.index), Array(0..<8), file: file, line: line)
        for page in book.pages {
            XCTAssertEqual(page.layout, .one, file: file, line: line)
            XCTAssertEqual(page.slots.count, 1, file: file, line: line)
            XCTAssertEqual(page.slots[0].kind, .empty, file: file, line: line)
            XCTAssertFalse(page.slots[0].hasPayload, file: file, line: line)
        }
    }
}
