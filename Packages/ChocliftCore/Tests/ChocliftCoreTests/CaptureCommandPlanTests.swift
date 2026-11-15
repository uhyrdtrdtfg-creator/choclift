import Foundation
import XCTest
@testable import ChocliftCore

#if canImport(AppKit)
import AppKit
#endif

final class CaptureCommandPlanTests: XCTestCase {
    func testCatalogContainsCapturePackActionsWithTitlesAndSymbols() throws {
        let pack = CompanionActionCatalog.capturePack
        XCTAssertEqual(
            pack.map(\.id),
            ["capture.window_to_clipboard", "capture.screen_to_desktop"]
        )

        let windowAction = try XCTUnwrap(CompanionActionCatalog.action(id: "capture.window_to_clipboard"))
        let screenAction = try XCTUnwrap(CompanionActionCatalog.action(id: "capture.screen_to_desktop"))

        XCTAssertTrue(CompanionActionCatalog.isKnown("capture.window_to_clipboard"))
        XCTAssertTrue(CompanionActionCatalog.isKnown("capture.screen_to_desktop"))
        XCTAssertEqual(windowAction.titleZh, "窗口截图到剪贴板")
        XCTAssertEqual(windowAction.titleEn, "Window to Clipboard")
        XCTAssertEqual(windowAction.sfSymbol, "camera.metering.spot")
        XCTAssertEqual(screenAction.titleZh, "全屏截图到桌面")
        XCTAssertEqual(screenAction.titleEn, "Screen to Desktop")
        XCTAssertEqual(screenAction.sfSymbol, "camera")

        #if canImport(AppKit)
        for action in pack {
            XCTAssertNotNil(
                NSImage(systemSymbolName: action.sfSymbol, accessibilityDescription: nil),
                "Missing SF Symbol on macOS: \(action.sfSymbol)"
            )
        }
        #endif
    }

    func testWindowToClipboardCommandPlanUsesWindowIDAndRejectsMissingOrZeroID() throws {
        let desktopURL = URL(fileURLWithPath: "/Users/tester/Desktop", isDirectory: true)
        let spec = try CaptureCommandPlan.buildCommandSpec(
            for: "capture.window_to_clipboard",
            frontWindowID: { 4821 },
            desktopDirectoryURL: desktopURL,
            fileExists: { _ in false }
        ).get()

        XCTAssertEqual(spec.executablePath, "/usr/sbin/screencapture")
        XCTAssertEqual(spec.executableURL, URL(fileURLWithPath: "/usr/sbin/screencapture"))
        XCTAssertEqual(spec.arguments, ["-l", "4821", "-c"])
        XCTAssertNil(spec.outputFileURL)
        XCTAssertFalse(spec.arguments.contains("-i"))
        XCTAssertFalse(spec.arguments.contains("-w"))

        XCTAssertEqual(
            CaptureCommandPlan.windowToClipboardArguments(windowID: nil),
            .failure(.frontWindowUnavailable)
        )
        XCTAssertEqual(
            CaptureCommandPlan.windowToClipboardArguments(windowID: 0),
            .failure(.frontWindowUnavailable)
        )
        XCTAssertEqual(
            CaptureCommandPlan.buildCommandSpec(
                for: "capture.window_to_clipboard",
                frontWindowID: { nil },
                desktopDirectoryURL: desktopURL,
                fileExists: { _ in false }
            ),
            .failure(.frontWindowUnavailable)
        )
    }

    func testDesktopFileNameAndScreenToDesktopPlanApplyNoOverwriteSuffix() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        components.timeZone = utc
        components.year = 2026
        components.month = 11
        components.day = 15
        components.hour = 22
        components.minute = 30
        components.second = 49
        let sampleDate = try XCTUnwrap(components.date)

        XCTAssertEqual(
            CaptureCommandPlan.desktopFileName(for: sampleDate, timeZone: utc, existingFileNames: []),
            "Choclift-20261115-223049.png"
        )
        XCTAssertEqual(
            CaptureCommandPlan.desktopFileName(
                for: sampleDate,
                timeZone: utc,
                existingFileNames: ["Choclift-20261115-223049.png"]
            ),
            "Choclift-20261115-223049-2.png"
        )
        XCTAssertEqual(
            CaptureCommandPlan.desktopFileName(
                for: sampleDate,
                timeZone: utc,
                existingFileNames: [
                    "Choclift-20261115-223049.png",
                    "Choclift-20261115-223049-2.png",
                    "Choclift-20261115-223049-3.png"
                ]
            ),
            "Choclift-20261115-223049-4.png"
        )

        let fm = FileManager.default
        let tempDesktop = fm.temporaryDirectory.appendingPathComponent(
            "choclift-capture-plan-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempDesktop, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDesktop) }

        let firstSpec = try CaptureCommandPlan.buildCommandSpec(
            for: "capture.screen_to_desktop",
            frontWindowID: { XCTFail("Should not query front window ID for full-screen capture"); return nil },
            desktopDirectoryURL: tempDesktop,
            now: sampleDate,
            timeZone: utc
        ).get()
        let firstURL = tempDesktop.appendingPathComponent("Choclift-20261115-223049.png")
        XCTAssertEqual(firstSpec.executablePath, "/usr/sbin/screencapture")
        XCTAssertEqual(firstSpec.arguments, [firstURL.path])
        XCTAssertEqual(firstSpec.outputFileURL, firstURL)
        XCTAssertFalse(firstSpec.arguments.contains("-i"))

        try Data("existing".utf8).write(to: firstURL)
        let secondSpec = try CaptureCommandPlan.buildCommandSpec(
            for: "capture.screen_to_desktop",
            frontWindowID: { nil },
            desktopDirectoryURL: tempDesktop,
            now: sampleDate,
            timeZone: utc
        ).get()
        let secondURL = tempDesktop.appendingPathComponent("Choclift-20261115-223049-2.png")
        XCTAssertEqual(secondSpec.arguments, [secondURL.path])
        XCTAssertEqual(secondSpec.outputFileURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), Data("existing".utf8))
    }

    func testExecuteReportsScreenRecordingPermissionHintOnNonZeroExitWithoutLaunchingProcess() {
        var executedSpecs: [CaptureCommandSpec] = []

        let missingWindowResult = CaptureCommandPlan.execute(
            id: "capture.window_to_clipboard",
            language: .english,
            frontWindowID: { nil },
            desktopDirectoryURL: { .failure(.desktopDirectoryUnavailable) },
            runProcess: { spec in
                executedSpecs.append(spec)
                return .success(CaptureProcessResult(exitCode: 0))
            }
        )
        XCTAssertFalse(missingWindowResult.success)
        XCTAssertTrue(executedSpecs.isEmpty)

        let nonZeroEn = CaptureCommandPlan.execute(
            id: "capture.window_to_clipboard",
            language: .english,
            frontWindowID: { 901 },
            desktopDirectoryURL: { .failure(.desktopDirectoryUnavailable) },
            runProcess: { spec in
                executedSpecs.append(spec)
                return .success(
                    CaptureProcessResult(
                        exitCode: 1,
                        stderr: "could not create image from window\n"
                    )
                )
            }
        )
        XCTAssertFalse(nonZeroEn.success)
        XCTAssertEqual(executedSpecs.count, 1)
        XCTAssertEqual(executedSpecs.first?.arguments, ["-l", "901", "-c"])
        XCTAssertTrue(nonZeroEn.message.contains("Screen Recording"))
        XCTAssertTrue(nonZeroEn.message.contains("could not create image from window"))

        let nonZeroZh = CaptureCommandPlan.execute(
            id: "capture.screen_to_desktop",
            language: .chinese,
            frontWindowID: { nil },
            desktopDirectoryURL: { .success(URL(fileURLWithPath: "/Users/tester/Desktop", isDirectory: true)) },
            fileExists: { _ in false },
            runProcess: { _ in
                .success(CaptureProcessResult(exitCode: 1, stderr: "could not create image from display"))
            }
        )
        XCTAssertFalse(nonZeroZh.success)
        XCTAssertTrue(nonZeroZh.message.contains("屏幕录制"))
        XCTAssertTrue(nonZeroZh.message.contains("could not create image from display"))
    }

    func testFrontWindowResolverPrefersFocusedFrameAndSkipsSelfOrTinyHelperWindows() {
        let candidates: [CaptureWindowCandidate] = [
            CaptureWindowCandidate(
                windowID: 10,
                ownerPID: 777,
                layer: 0,
                alpha: 1.0,
                bounds: WindowQuartzRect(x: 0, y: 0, width: 900, height: 700)
            ),
            CaptureWindowCandidate(
                windowID: 11,
                ownerPID: 500,
                layer: 25,
                alpha: 1.0,
                bounds: WindowQuartzRect(x: 0, y: 0, width: 300, height: 24)
            ),
            CaptureWindowCandidate(
                windowID: 12,
                ownerPID: 500,
                layer: 0,
                alpha: 1.0,
                bounds: WindowQuartzRect(x: 0, y: 0, width: 1, height: 1)
            ),
            CaptureWindowCandidate(
                windowID: 13,
                ownerPID: 500,
                layer: 0,
                alpha: 1.0,
                bounds: WindowQuartzRect(x: 80, y: 80, width: 1100, height: 760)
            ),
            CaptureWindowCandidate(
                windowID: 14,
                ownerPID: 500,
                layer: 0,
                alpha: 1.0,
                bounds: WindowQuartzRect(x: 220, y: 140, width: 980, height: 680)
            )
        ]

        let matchedFocused = CaptureFrontWindowResolver.resolveWindowID(
            candidates: candidates,
            primaryPID: 500,
            primaryFocusedFrame: WindowQuartzRect(x: 222, y: 141, width: 980, height: 680),
            eligibleOwnerPIDs: [500],
            selfPID: 777
        )
        XCTAssertEqual(matchedFocused, 14)

        let matchedZOrder = CaptureFrontWindowResolver.resolveWindowID(
            candidates: candidates,
            primaryPID: 500,
            primaryFocusedFrame: nil,
            eligibleOwnerPIDs: [500],
            selfPID: 777
        )
        XCTAssertEqual(matchedZOrder, 13)

        let selfOnly = CaptureFrontWindowResolver.resolveWindowID(
            candidates: [candidates[0]],
            primaryPID: nil,
            fallbackPID: nil,
            eligibleOwnerPIDs: [500],
            selfPID: 777
        )
        XCTAssertNil(selfOnly)
    }
}
