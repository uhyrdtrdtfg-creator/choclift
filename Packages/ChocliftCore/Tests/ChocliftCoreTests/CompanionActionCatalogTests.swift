import XCTest
@testable import ChocliftCore

final class CompanionActionCatalogTests: XCTestCase {
    func testCatalogStartsEmptyAndRejectsUnknownIds() {
        XCTAssertTrue(CompanionActionCatalog.all.isEmpty)
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
