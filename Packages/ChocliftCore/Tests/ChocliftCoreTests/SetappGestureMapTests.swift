import Foundation
import XCTest
@testable import ChocliftCore

final class SetappGestureMapTests: XCTestCase {

    func testAllEightFingerDirectionCombinationsMapToExpectedEffects() {
        XCTAssertEqual(SetappFingerCount.allCases, [.one, .two, .three, .four])
        XCTAssertEqual(SetappSwipeDirection.allCases, [.up, .down])
        XCTAssertEqual(
            SetappGestureEffect.allCases,
            [.minimizeApp, .maximizeApp, .copySelection, .pasteClipboard]
        )

        XCTAssertEqual(SetappGestureMap.effect(fingers: .one, direction: .down), .minimizeApp)
        XCTAssertEqual(SetappGestureMap.effect(fingers: .one, direction: .up), .maximizeApp)
        XCTAssertEqual(SetappGestureMap.effect(fingers: .two, direction: .down), .minimizeApp)
        XCTAssertEqual(SetappGestureMap.effect(fingers: .two, direction: .up), .maximizeApp)
        XCTAssertEqual(SetappGestureMap.effect(fingers: .three, direction: .down), .copySelection)
        XCTAssertEqual(SetappGestureMap.effect(fingers: .three, direction: .up), .pasteClipboard)
        XCTAssertEqual(SetappGestureMap.effect(fingers: .four, direction: .down), .copySelection)
        XCTAssertEqual(SetappGestureMap.effect(fingers: .four, direction: .up), .pasteClipboard)
    }

    func testEnglishTitlesMatchSetappUICopyStrings() {
        let expected: [(SetappFingerCount, SetappSwipeDirection, String)] = [
            (.one, .down, "Swipe down anywhere with one finger to minimize (hide) an app."),
            (.one, .up, "Swipe up anywhere with one finger to maximize an app."),
            (.two, .down, "Swipe down anywhere with two fingers to minimize (hide) an app."),
            (.two, .up, "Swipe up anywhere with two fingers to maximize an app."),
            (.three, .down, "Swipe down anywhere with three fingers to copy content to your clipboard."),
            (.three, .up, "Swipe up anywhere with three fingers to paste content from your clipboard."),
            (.four, .down, "Swipe down anywhere with four fingers to copy content to your clipboard."),
            (.four, .up, "Swipe up anywhere with four fingers to paste content from your clipboard.")
        ]

        for (fingers, direction, expectedEn) in expected {
            XCTAssertEqual(
                SetappGestureMap.titleEn(fingers: fingers, direction: direction),
                expectedEn
            )
            XCTAssertEqual(
                SetappGestureMap.title(fingers: fingers, direction: direction, in: .english),
                expectedEn
            )
            XCTAssertEqual(
                SetappGestureMap.entry(fingers: fingers, direction: direction).title(in: .english),
                expectedEn
            )
        }
    }

    func testChineseTitlesMatchSetappUICopyStrings() {
        let expected: [(SetappFingerCount, SetappSwipeDirection, String)] = [
            (.one, .down, "用一根手指向下滑动即可最小化（隐藏）应用。"),
            (.one, .up, "用一根手指向上滑动即可最大化应用。"),
            (.two, .down, "两指任意处向下滑动以最小化（隐藏）App。"),
            (.two, .up, "两指任意处向上滑动以最大化 App。"),
            (.three, .down, "三指任意处向下滑动以复制到剪贴板。"),
            (.three, .up, "三指任意处向上滑动以从剪贴板粘贴。"),
            (.four, .down, "四指任意处向下滑动以复制到剪贴板。"),
            (.four, .up, "四指任意处向上滑动以从剪贴板粘贴。")
        ]

        for (fingers, direction, expectedZh) in expected {
            XCTAssertEqual(
                SetappGestureMap.titleZh(fingers: fingers, direction: direction),
                expectedZh
            )
            XCTAssertEqual(
                SetappGestureMap.title(fingers: fingers, direction: direction, in: .chinese),
                expectedZh
            )
            XCTAssertEqual(
                SetappGestureMap.entry(fingers: fingers, direction: direction).title(in: .chinese),
                expectedZh
            )
        }
    }

    func testSectionAndHeaderCopyMatchSetappStrings() {
        XCTAssertEqual(SetappGestureMap.headerTitleEn, "Delicious Gestures 🤤")
        XCTAssertEqual(SetappGestureMap.headerTitleZh, "美味手势 🤤")
        XCTAssertEqual(SetappGestureMap.windowSectionTitleEn, "Window Management")
        XCTAssertEqual(SetappGestureMap.windowSectionTitleZh, "窗口管理")
        XCTAssertEqual(SetappGestureMap.clipboardSectionTitleEn, "Copy/Paste")
        XCTAssertEqual(SetappGestureMap.clipboardSectionTitleZh, "复制/粘贴")
        XCTAssertEqual(SetappGestureMap.comingSoonTitleEn, "More gestures coming soon")
        XCTAssertEqual(SetappGestureMap.comingSoonTitleZh, "更多手势即将推出")

        XCTAssertEqual(SetappGestureEffect.minimizeApp.sectionTitle(in: .english), "Window Management")
        XCTAssertEqual(SetappGestureEffect.maximizeApp.sectionTitle(in: .chinese), "窗口管理")
        XCTAssertEqual(SetappGestureEffect.copySelection.sectionTitle(in: .english), "Copy/Paste")
        XCTAssertEqual(SetappGestureEffect.pasteClipboard.sectionTitle(in: .chinese), "复制/粘贴")

        for effect in SetappGestureEffect.allCases {
            XCTAssertFalse(effect.title(in: .english).isEmpty)
            XCTAssertFalse(effect.title(in: .chinese).isEmpty)
        }
    }

    func testAllCombinationsCatalogAndTouchCountInitAndCodableRoundTrip() throws {
        XCTAssertEqual(SetappGestureMap.allCombinations.count, 8)
        XCTAssertEqual(Set(SetappGestureMap.allCombinations.map(\.id)).count, 8)

        XCTAssertEqual(SetappFingerCount(touchCount: 1), .one)
        XCTAssertEqual(SetappFingerCount(touchCount: 2), .two)
        XCTAssertEqual(SetappFingerCount(touchCount: 3), .three)
        XCTAssertEqual(SetappFingerCount(touchCount: 4), .four)
        XCTAssertNil(SetappFingerCount(touchCount: 0))
        XCTAssertNil(SetappFingerCount(touchCount: 5))
        XCTAssertNil(SetappFingerCount(touchCount: -1))

        let encoded = try JSONEncoder().encode(SetappGestureMap.allCombinations)
        let decoded = try JSONDecoder().decode([SetappGestureEntry].self, from: encoded)
        XCTAssertEqual(decoded, SetappGestureMap.allCombinations)
    }
}
