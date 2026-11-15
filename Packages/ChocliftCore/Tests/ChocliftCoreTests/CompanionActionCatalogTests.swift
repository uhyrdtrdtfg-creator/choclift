import XCTest
@testable import ChocliftCore

final class CompanionActionCatalogTests: XCTestCase {
    func testCatalogListsFiftyUniqueActionsAndRejectsUnknownIds() {
        let ids = CompanionActionCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, 50)
        XCTAssertEqual(Set(ids).count, 50)
        XCTAssertEqual(ids.filter { $0.hasPrefix("window.") }.count, 10)
        XCTAssertEqual(ids.filter { $0.hasPrefix("media.") }.count, 10)
        XCTAssertEqual(ids.filter { $0.hasPrefix("files.") }.count, 10)
        XCTAssertEqual(ids.filter { $0.hasPrefix("edit.") }.count, 10)
        XCTAssertEqual(ids.filter { $0.hasPrefix("system.") }.count, 10)
        XCTAssertNil(CompanionActionCatalog.action(id: "not_a_real_action"))
        XCTAssertFalse(CompanionActionCatalog.isKnown("not_a_real_action"))
    }

    func testPerformCompanionActionRoundTrips() throws {
        let message = ClientMessage.performCompanionAction(id: "window.example")
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)
        XCTAssertEqual(decoded, message)
    }
}
