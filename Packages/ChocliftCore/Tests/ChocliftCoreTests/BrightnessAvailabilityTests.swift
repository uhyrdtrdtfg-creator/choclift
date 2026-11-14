import XCTest
@testable import ChocliftCore

final class BrightnessAvailabilityTests: XCTestCase {
    func testUnavailablePlusConnectedDisablesSliderAndShowsUnsupportedDisplayCaption() {
        XCTAssertTrue(
            CompanionBrightnessControlPolicy.isSliderDisabled(
                isConnected: true,
                isBrightnessAvailable: false
            )
        )

        let englishCaption = CompanionBrightnessControlPolicy.unavailableCaption(
            isConnected: true,
            isBrightnessAvailable: false,
            language: .english
        )
        XCTAssertEqual(englishCaption, "This display does not support system brightness")

        let chineseCaption = CompanionBrightnessControlPolicy.unavailableCaption(
            isConnected: true,
            isBrightnessAvailable: false,
            language: .chinese
        )
        XCTAssertEqual(chineseCaption, "当前显示器不支持系统亮度")
    }

    func testAvailableOrDisconnectedLeavesSliderEnabledWithoutCaption() {
        XCTAssertFalse(
            CompanionBrightnessControlPolicy.isSliderDisabled(
                isConnected: true,
                isBrightnessAvailable: true
            )
        )
        XCTAssertNil(
            CompanionBrightnessControlPolicy.unavailableCaption(
                isConnected: true,
                isBrightnessAvailable: true,
                language: .english
            )
        )
        XCTAssertNil(
            CompanionBrightnessControlPolicy.unavailableCaption(
                isConnected: true,
                isBrightnessAvailable: true,
                language: .chinese
            )
        )

        for available in [false, true] {
            XCTAssertFalse(
                CompanionBrightnessControlPolicy.isSliderDisabled(
                    isConnected: false,
                    isBrightnessAvailable: available
                )
            )
            XCTAssertNil(
                CompanionBrightnessControlPolicy.unavailableCaption(
                    isConnected: false,
                    isBrightnessAvailable: available,
                    language: .english
                )
            )
            XCTAssertNil(
                CompanionBrightnessControlPolicy.unavailableCaption(
                    isConnected: false,
                    isBrightnessAvailable: available,
                    language: .chinese
                )
            )
        }
    }

    func testControlStripStateUnavailableBrightnessFeedsPolicy() throws {
        let externalDisplayState = ControlStripState(
            volume: 0.5,
            isVolumeMuted: false,
            brightness: 0.75,
            isBrightnessAvailable: false
        )
        let roundTripped = try JSONDecoder().decode(
            ControlStripState.self,
            from: JSONEncoder().encode(externalDisplayState)
        )
        XCTAssertFalse(roundTripped.isBrightnessAvailable)
        XCTAssertTrue(
            CompanionBrightnessControlPolicy.isSliderDisabled(
                isConnected: true,
                isBrightnessAvailable: roundTripped.isBrightnessAvailable
            )
        )
    }
}
