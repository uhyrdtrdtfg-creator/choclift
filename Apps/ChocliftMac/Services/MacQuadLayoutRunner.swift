import AppKit
import ChocliftCore
import Foundation

@MainActor
public enum MacQuadLayoutRunner {
    private static let windowWaitMaxSteps = 20
    private static let windowWaitStepSeconds: TimeInterval = 0.1

    public static func accessibilityDeniedMessage(in lang: AppLanguage = .system) -> String {
        L10n.tr(
            "请在系统设置 → 辅助功能中授权 Choclift 控制窗口",
            "Grant Accessibility permission in System Settings to control windows",
            language: lang
        )
    }

    public static func run(
        _ layout: QuadAppLayout,
        windowService: MacAccessibilityAndWindowService,
        language: AppLanguage = .system
    ) async -> (success: Bool, message: String) {
        guard windowService.isAccessibilityTrusted() else {
            _ = windowService.promptForAccessibilityPermission()
            return (false, accessibilityDeniedMessage(in: language))
        }

        let selfBundleID = Bundle.main.bundleIdentifier ?? "com.choclift.mac"
        let selfPID = ProcessInfo.processInfo.processIdentifier

        var slotsToRun: [(corner: QuadCorner, slot: QuadAppSlot)] = []
        for corner in QuadCorner.allCases {
            guard let slot = layout.slot(for: corner) else { continue }
            let trimmedBundle = slot.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBundle.isEmpty
                || QuadAppSlot.isChocliftBundleIdentifier(trimmedBundle)
                || trimmedBundle.caseInsensitiveCompare(selfBundleID) == .orderedSame {
                continue
            }
            slotsToRun.append((corner, slot))
        }

        guard !slotsToRun.isEmpty else {
            return (
                false,
                L10n.tr(
                    "四宫格布局中没有可打开的应用",
                    "Quad layout has no apps to open",
                    language: language
                )
            )
        }

        windowService.beginWindowUndoTransaction()
        defer { windowService.commitWindowUndoTransaction() }

        var snappedCount = 0
        var failures: [String] = []

        for (corner, slot) in slotsToRun {
            guard windowService.isAccessibilityTrusted() else {
                _ = windowService.promptForAccessibilityPermission()
                return (false, accessibilityDeniedMessage(in: language))
            }

            let bundleID = slot.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = slot.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? bundleID
                : slot.appName

            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                failures.append(
                    L10n.tr(
                        "\(corner.title(in: language))：未找到 \(label)",
                        "\(corner.title(in: language)): \(label) not found",
                        language: language
                    )
                )
                continue
            }

            let targetApp: NSRunningApplication
            if let existing = runningApplication(forBundleIdentifier: bundleID) {
                if existing.processIdentifier == selfPID {
                    continue
                }
                existing.unhide()
                windowService.unminimizeFirstWindowIfAllMinimized(pid: existing.processIdentifier)
                existing.activate(options: [.activateAllWindows])
                if windowService.hasAdjustableWindow(forPID: existing.processIdentifier) {
                    targetApp = existing
                } else {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    do {
                        let reopened = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
                        await waitForAdjustableWindow(pid: reopened.processIdentifier, windowService: windowService)
                        targetApp = reopened
                    } catch {
                        failures.append("\(corner.title(in: language)): \(error.localizedDescription)")
                        continue
                    }
                }
            } else {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                do {
                    let launched = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
                    if launched.processIdentifier == selfPID {
                        continue
                    }
                    await waitForAdjustableWindow(pid: launched.processIdentifier, windowService: windowService)
                    targetApp = launched
                } catch {
                    failures.append("\(corner.title(in: language)): \(error.localizedDescription)")
                    continue
                }
            }

            guard windowService.isAccessibilityTrusted() else {
                _ = windowService.promptForAccessibilityPermission()
                return (false, accessibilityDeniedMessage(in: language))
            }

            let snapOutcome = windowService.applyCompanionWindowFrame(
                preferredPID: targetApp.processIdentifier,
                strictTargetPID: true
            ) { _, _, appName, _, visibleQuartz, _, _, _ in
                let targetFrame = WindowDisplayGeometry.quarterFrame(
                    for: corner.windowQuarterCorner,
                    visibleQuartz: visibleQuartz
                )
                return .success((
                    frame: targetFrame,
                    message: L10n.tr(
                        "已将 \(appName) 贴靠\(corner.title(in: language))",
                        "Snapped \(appName) to \(corner.title(in: language))",
                        language: language
                    )
                ))
            }

            guard windowService.isAccessibilityTrusted() else {
                return (false, accessibilityDeniedMessage(in: language))
            }

            if snapOutcome.success {
                snappedCount += 1
            } else {
                failures.append("\(corner.title(in: language)): \(snapOutcome.message)")
            }
        }

        if failures.isEmpty && snappedCount > 0 {
            return (
                true,
                L10n.tr(
                    "已运行四宫格「\(layout.name)」（\(snappedCount) 个窗口）",
                    "Arranged \"\(layout.name)\" (\(snappedCount) window(s))",
                    language: language
                )
            )
        }

        return (false, failures.joined(separator: "；"))
    }

    private static func runningApplication(forBundleIdentifier bundleID: String) -> NSRunningApplication? {
        if let direct = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }) {
            return direct
        }
        return NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated &&
            $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }

    private static func waitForAdjustableWindow(
        pid: pid_t,
        windowService: MacAccessibilityAndWindowService
    ) async {
        windowService.unminimizeFirstWindowIfAllMinimized(pid: pid)
        if windowService.hasAdjustableWindow(forPID: pid) {
            return
        }
        for _ in 0..<windowWaitMaxSteps {
            if Task.isCancelled { return }
            await CancellableDelay.sleepUntilCancelled(seconds: windowWaitStepSeconds)
            if Task.isCancelled { return }
            windowService.unminimizeFirstWindowIfAllMinimized(pid: pid)
            if windowService.hasAdjustableWindow(forPID: pid) {
                return
            }
        }
    }
}
