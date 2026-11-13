import AppKit
import ChocliftCore
import Foundation

@MainActor
public final class MacOrcaStatusService {
    private static let orcaBundleIdentifier = "com.stablyai.orca"
    private static let subprocessTimeoutSeconds: TimeInterval = 3.5
    private static let titleCacheRefreshInterval: TimeInterval = 15.0
    private static let maxCachedRuns = 8

    private struct RunTitleCacheEntry {
        var fetchedAt: Date
        var byTaskID: [String: String]
        var byDispatchID: [String: String]
    }

    private var focusTargetsByDispatchID: [String: OrcaFocusTarget] = [:]
    private var runTitleCache: [String: RunTitleCacheEntry] = [:]

    public init() {}

    public func pollStatus() async -> OrcaTaskStatusSnapshot {
        guard let executablePath = OrcaCommandBuilder.resolveExecutablePath() else {
            focusTargetsByDispatchID.removeAll()
            return OrcaTaskStatusSnapshot(isOrcaRunning: false, tasks: [])
        }

        guard let workerSpec = try? OrcaCommandBuilder.workerListCommand(
            executablePath: executablePath,
            limit: 25,
            full: true
        ) else {
            focusTargetsByDispatchID.removeAll()
            return OrcaTaskStatusSnapshot(isOrcaRunning: false, tasks: [])
        }

        let workerOutput = await Self.runSubprocess(workerSpec)
        guard workerOutput.exitCode == 0, !workerOutput.stdout.isEmpty else {
            focusTargetsByDispatchID.removeAll()
            return OrcaTaskStatusSnapshot(isOrcaRunning: false, tasks: [])
        }

        let initialEntries: [ParsedOrcaWorkerEntry]
        do {
            initialEntries = try OrcaWorkerListParser.parseEntries(workerOutput.stdout)
        } catch {
            focusTargetsByDispatchID.removeAll()
            return OrcaTaskStatusSnapshot(isOrcaRunning: false, tasks: [])
        }

        await refreshTaskTitlesIfNeeded(
            for: initialEntries,
            executablePath: executablePath
        )

        var mergedByTaskID: [String: String] = [:]
        var mergedByDispatchID: [String: String] = [:]
        for cached in runTitleCache.values {
            mergedByTaskID.merge(cached.byTaskID) { current, _ in current }
            mergedByDispatchID.merge(cached.byDispatchID) { current, _ in current }
        }

        let resolvedEntries = (try? OrcaWorkerListParser.parseEntries(
            workerOutput.stdout,
            taskTitlesByID: mergedByTaskID,
            taskTitlesByDispatchID: mergedByDispatchID
        )) ?? initialEntries

        var nextTargets: [String: OrcaFocusTarget] = [:]
        for entry in resolvedEntries {
            if entry.item.canTapToFocus, let target = entry.focusTarget {
                nextTargets[entry.item.dispatchID] = target
            }
        }
        focusTargetsByDispatchID = nextTargets

        return OrcaWorkerListParser.buildWireSnapshot(from: resolvedEntries)
    }

    public func focusTaskWindow(
        dispatchID: String,
        language lang: AppLanguage,
        windowService: MacAccessibilityAndWindowService
    ) async -> (success: Bool, message: String) {
        guard let safeDispatchID = OrcaWorkerListParser.sanitizeDispatchID(dispatchID),
              let target = focusTargetsByDispatchID[safeDispatchID],
              target.state.isRunningOrFailed else {
            return (
                false,
                L10n.tr("该任务当前没有可聚焦的窗口", "That Orca task no longer has a focusable window", language: lang)
            )
        }

        guard let orcaApp = Self.runningOrcaApplication() else {
            return (
                false,
                L10n.tr("Orca 未运行", "Orca is not running", language: lang)
            )
        }

        var didSwitchInOrca = false
        if let executablePath = OrcaCommandBuilder.resolveExecutablePath() {
            if let terminalHandle = target.terminalHandle,
               let termSpec = try? OrcaCommandBuilder.terminalSwitchCommand(
                   executablePath: executablePath,
                   terminalHandle: terminalHandle
               ) {
                let res = await Self.runSubprocess(termSpec)
                didSwitchInOrca = (res.exitCode == 0)
            }

            if !didSwitchInOrca,
               let workspaceSelector = target.workspaceSelector,
               let wsSpec = try? OrcaCommandBuilder.worktreeActivateCommand(
                   executablePath: executablePath,
                   workspaceSelector: workspaceSelector
               ) {
                let res = await Self.runSubprocess(wsSpec)
                didSwitchInOrca = (res.exitCode == 0)
            }
        }

        orcaApp.unhide()
        windowService.unminimizeFirstWindowIfAllMinimized(pid: orcaApp.processIdentifier)
        windowService.raiseWindowMatchingTitleHint(target.workspaceHint, forPID: orcaApp.processIdentifier)
        let activated = orcaApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        if activated || didSwitchInOrca {
            return (
                true,
                L10n.tr("已切换到 Orca 窗口", "Switched to Orca window", language: lang)
            )
        }
        return (
            false,
            L10n.tr("无法激活 Orca 窗口", "Unable to bring Orca window to front", language: lang)
        )
    }

    // MARK: - Helpers

    private func refreshTaskTitlesIfNeeded(
        for entries: [ParsedOrcaWorkerEntry],
        executablePath: String
    ) async {
        var candidateRunIDs: [String] = []
        if let firstRun = entries.first?.runID {
            candidateRunIDs.append(firstRun)
        }
        for entry in entries where entry.item.state.isRunningOrFailed {
            if let runID = entry.runID, !candidateRunIDs.contains(runID) {
                candidateRunIDs.append(runID)
            }
            if candidateRunIDs.count >= 2 {
                break
            }
        }

        let now = Date()
        for runID in candidateRunIDs {
            if let existing = runTitleCache[runID],
               now.timeIntervalSince(existing.fetchedAt) < Self.titleCacheRefreshInterval {
                continue
            }
            guard let taskSpec = try? OrcaCommandBuilder.taskListCommand(
                executablePath: executablePath,
                runID: runID
            ) else {
                continue
            }
            let output = await Self.runSubprocess(taskSpec)
            guard output.exitCode == 0, !output.stdout.isEmpty else {
                continue
            }
            let parsed = OrcaWorkerListParser.parseTaskTitles(output.stdout)
            runTitleCache[runID] = RunTitleCacheEntry(
                fetchedAt: now,
                byTaskID: parsed.byTaskID,
                byDispatchID: parsed.byDispatchID
            )
        }

        if runTitleCache.count > Self.maxCachedRuns {
            let sortedKeys = runTitleCache.sorted { $0.value.fetchedAt < $1.value.fetchedAt }.map(\.key)
            for key in sortedKeys.prefix(runTitleCache.count - Self.maxCachedRuns) {
                runTitleCache.removeValue(forKey: key)
            }
        }
    }

    private static func runningOrcaApplication() -> NSRunningApplication? {
        if let direct = NSRunningApplication.runningApplications(withBundleIdentifier: orcaBundleIdentifier)
            .first(where: { !$0.isTerminated }) {
            return direct
        }
        return NSWorkspace.shared.runningApplications.first { app in
            guard !app.isTerminated else { return false }
            if app.bundleIdentifier?.caseInsensitiveCompare(orcaBundleIdentifier) == .orderedSame {
                return true
            }
            return app.bundleURL?.lastPathComponent.caseInsensitiveCompare("Orca.app") == .orderedSame
        }
    }

    private struct SubprocessResult: Sendable {
        let exitCode: Int32
        let stdout: Data
    }

    private static func runSubprocess(_ spec: OrcaCommandSpec) async -> SubprocessResult {
        let cleanEnv = OrcaCommandBuilder.cleanSubprocessEnvironment()
        let timeout = subprocessTimeoutSeconds
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: spec.executablePath)
                process.arguments = spec.arguments
                process.environment = cleanEnv

                let stdoutPipe = Pipe()
                process.standardOutput = stdoutPipe
                if let devNull = FileHandle(forWritingAtPath: "/dev/null") {
                    process.standardError = devNull
                } else {
                    process.standardError = Pipe()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: SubprocessResult(exitCode: -1, stdout: Data()))
                    return
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        process.terminate()
                    }
                }

                let rawData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let cappedData = rawData.count > 2_097_152 ? rawData.prefix(2_097_152) : rawData
                continuation.resume(
                    returning: SubprocessResult(
                        exitCode: process.terminationStatus,
                        stdout: Data(cappedData)
                    )
                )
            }
        }
    }
}
