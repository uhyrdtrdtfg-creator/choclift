import Foundation

// MARK: - Orca Task Wire Models (Minimal Safe Companion Payload)

public enum OrcaTaskState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case working
    case waiting
    case failed
    case idle

    public var isRunningOrFailed: Bool {
        switch self {
        case .working, .waiting, .failed:
            return true
        case .idle:
            return false
        }
    }

    public var sfSymbol: String {
        switch self {
        case .working:
            return "bolt.horizontal.circle.fill"
        case .waiting:
            return "pause.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .idle:
            return "checkmark.circle"
        }
    }

    public func label(in lang: AppLanguage = .system) -> String {
        switch self {
        case .working:
            return L10n.tr("运行中", "Working", language: lang)
        case .waiting:
            return L10n.tr("等待中", "Waiting", language: lang)
        case .failed:
            return L10n.tr("已失败", "Failed", language: lang)
        case .idle:
            return L10n.tr("空闲", "Idle", language: lang)
        }
    }
}

/// Companion-safe Orca task row. Intentionally carries ONLY dispatchID, state, title, and canFocusWindow
/// so daemon tokens, pairing codes, environment variables, terminal handles, and transcripts never cross the wire.
public struct OrcaTaskStatusItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var dispatchID: String
    public var state: OrcaTaskState
    public var title: String?
    public var canFocusWindow: Bool

    public var id: String {
        dispatchID.isEmpty ? "orca-idle" : dispatchID
    }

    public var canTapToFocus: Bool {
        state.isRunningOrFailed && canFocusWindow && !dispatchID.isEmpty
    }

    public init(
        dispatchID: String,
        state: OrcaTaskState,
        title: String? = nil,
        canFocusWindow: Bool = false
    ) {
        self.dispatchID = dispatchID
        self.state = state
        self.title = title
        self.canFocusWindow = state.isRunningOrFailed ? canFocusWindow : false
    }
}

public struct OrcaTaskStatusSnapshot: Codable, Equatable, Hashable, Sendable {
    public var isOrcaRunning: Bool
    public var tasks: [OrcaTaskStatusItem]

    public init(isOrcaRunning: Bool, tasks: [OrcaTaskStatusItem] = []) {
        self.isOrcaRunning = isOrcaRunning
        self.tasks = isOrcaRunning ? tasks : []
    }

    /// Rows to display when Orca is running: active/failed tasks if present, otherwise a single idle row.
    public var displayRows: [OrcaTaskStatusItem] {
        guard isOrcaRunning else { return [] }
        if tasks.isEmpty {
            return [OrcaTaskStatusItem(dispatchID: "", state: .idle, title: nil, canFocusWindow: false)]
        }
        return tasks
    }

    /// Single highest-signal row for compact surfaces such as Apple Watch.
    public var primaryRow: OrcaTaskStatusItem? {
        let rows = displayRows
        guard !rows.isEmpty else { return nil }
        if let waiting = rows.first(where: { $0.state == .waiting }) {
            return waiting
        }
        if let failed = rows.first(where: { $0.state == .failed }) {
            return failed
        }
        if let working = rows.first(where: { $0.state == .working }) {
            return working
        }
        return rows.first
    }
}

// MARK: - Mac-Local Focus Metadata (Never Sent Over Wire)

public struct OrcaFocusTarget: Equatable, Sendable {
    public let dispatchID: String
    public let state: OrcaTaskState
    public let terminalHandle: String?
    public let workspaceSelector: String?
    public let workspaceHint: String?

    public init(
        dispatchID: String,
        state: OrcaTaskState,
        terminalHandle: String?,
        workspaceSelector: String?,
        workspaceHint: String?
    ) {
        self.dispatchID = dispatchID
        self.state = state
        self.terminalHandle = terminalHandle
        self.workspaceSelector = workspaceSelector
        self.workspaceHint = workspaceHint
    }
}

public struct ParsedOrcaWorkerEntry: Equatable, Sendable {
    public let item: OrcaTaskStatusItem
    public let taskID: String?
    public let runID: String?
    public let focusTarget: OrcaFocusTarget?

    public init(
        item: OrcaTaskStatusItem,
        taskID: String? = nil,
        runID: String? = nil,
        focusTarget: OrcaFocusTarget? = nil
    ) {
        self.item = item
        self.taskID = taskID
        self.runID = runID
        self.focusTarget = focusTarget
    }
}

// MARK: - Read-Only & Focus CLI Argument Builder (No Shell, No Dispatch, No Git)

public enum OrcaCommandError: Error, Equatable, Sendable {
    case binaryNotFound
    case unsafeExecutablePath
    case invalidIdentifier
}

public struct OrcaCommandSpec: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

public enum OrcaCommandBuilder {
    public static let allowedCandidatePaths: [String] = [
        "/usr/local/bin/orca",
        "/Applications/Orca.app/Contents/Resources/bin/orca"
    ]

    private static let forbiddenExecutableNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "csh", "tcsh", "ksh", "env", "git", "gh"
    ]

    public static func resolveExecutablePath(
        fileManager: FileManager = .default,
        candidates: [String] = allowedCandidatePaths
    ) -> String? {
        for path in candidates {
            guard (try? validateExecutablePath(path)) != nil else { continue }
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    public static func validateExecutablePath(_ rawPath: String) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              !trimmed.contains("\0"),
              !trimmed.contains("\n"),
              !trimmed.contains("\r") else {
            throw OrcaCommandError.unsafeExecutablePath
        }
        let base = URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
        guard base == "orca", !forbiddenExecutableNames.contains(base) else {
            throw OrcaCommandError.unsafeExecutablePath
        }
        return trimmed
    }

    /// Minimal clean environment for Orca subprocesses so inherited session/daemon/pairing variables
    /// neither leak nor bind `worker-list` / `task-list` to a single worker terminal.
    public static func cleanSubprocessEnvironment(
        homeDirectory: String = NSHomeDirectory()
    ) -> [String: String] {
        [
            "HOME": homeDirectory,
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8"
        ]
    }

    public static func workerListCommand(
        executablePath: String,
        limit: Int = 25,
        full: Bool = true
    ) throws -> OrcaCommandSpec {
        let exe = try validateExecutablePath(executablePath)
        let boundedLimit = min(max(1, limit), 100)
        var args = ["orchestration", "worker-list"]
        if full {
            args.append("--full")
        }
        args.append(contentsOf: ["--limit", "\(boundedLimit)", "--json"])
        return OrcaCommandSpec(executablePath: exe, arguments: args)
    }

    public static func taskListCommand(
        executablePath: String,
        runID: String
    ) throws -> OrcaCommandSpec {
        let exe = try validateExecutablePath(executablePath)
        let safeRunID = try validateSafeTokenIdentifier(runID)
        return OrcaCommandSpec(
            executablePath: exe,
            arguments: ["orchestration", "task-list", "--run", safeRunID, "--json"]
        )
    }

    public static func terminalSwitchCommand(
        executablePath: String,
        terminalHandle: String
    ) throws -> OrcaCommandSpec {
        let exe = try validateExecutablePath(executablePath)
        let safeHandle = try validateSafeTokenIdentifier(terminalHandle)
        return OrcaCommandSpec(
            executablePath: exe,
            arguments: ["terminal", "switch", "--terminal", safeHandle, "--json"]
        )
    }

    public static func worktreeActivateCommand(
        executablePath: String,
        workspaceSelector: String
    ) throws -> OrcaCommandSpec {
        let exe = try validateExecutablePath(executablePath)
        let trimmed = workspaceSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 512,
              !trimmed.hasPrefix("-"),
              !trimmed.contains("\0"),
              !trimmed.contains("\n"),
              !trimmed.contains("\r") else {
            throw OrcaCommandError.invalidIdentifier
        }
        return OrcaCommandSpec(
            executablePath: exe,
            arguments: ["worktree", "activate", "--worktree", trimmed, "--json"]
        )
    }

    private static func validateSafeTokenIdentifier(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 96,
              !trimmed.hasPrefix("-"),
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "." || scalar == ":"
              }) else {
            throw OrcaCommandError.invalidIdentifier
        }
        return trimmed
    }
}

// MARK: - Worker List JSON Parser & Sanitizer

public enum OrcaWorkerListParseError: Error, Equatable, Sendable {
    case invalidJSON
    case runtimeUnavailable
}

public enum OrcaWorkerListParser {
    private static let maxSafeTitleLength = 140

    private static let failedKeywords: Set<String> = [
        "failed", "failure", "error", "errored", "crashed", "timed_out", "timeout"
    ]

    private static let settledIdleKeywords: Set<String> = [
        "idle", "succeeded", "success", "completed", "complete", "done",
        "finished", "settled", "stopped", "cancelled", "canceled", "abandoned"
    ]

    private static let waitingKeywords: Set<String> = [
        "waiting", "blocked", "paused", "awaiting_input", "needs_input",
        "needs_attention", "input_required", "escalated", "escalation",
        "question", "pending_approval", "approval_required", "waiting_for_input"
    ]

    private static let workingKeywords: Set<String> = [
        "working", "running", "busy", "active", "in_progress",
        "starting", "provisioning", "launching", "executing", "dispatched"
    ]

    private static let releasedTerminalKeywords: Set<String> = [
        "released", "closed", "destroyed", "terminated"
    ]

    /// Parses `orca orchestration worker-list --json` (concise, `--full`, unwrapped object, or array)
    /// into sanitized companion status items.
    public static func parseItems(
        _ data: Data,
        taskTitlesByID: [String: String] = [:],
        taskTitlesByDispatchID: [String: String] = [:]
    ) throws -> [OrcaTaskStatusItem] {
        try parseEntries(
            data,
            taskTitlesByID: taskTitlesByID,
            taskTitlesByDispatchID: taskTitlesByDispatchID
        ).map(\.item)
    }

    public static func parseEntries(
        _ data: Data,
        taskTitlesByID: [String: String] = [:],
        taskTitlesByDispatchID: [String: String] = [:]
    ) throws -> [ParsedOrcaWorkerEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            throw OrcaWorkerListParseError.invalidJSON
        }

        let workerObjects = try extractWorkerDictionaries(from: root)
        var parsed: [ParsedOrcaWorkerEntry] = []
        parsed.reserveCapacity(workerObjects.count)

        for (index, dict) in workerObjects.enumerated() {
            let state = classifyState(from: dict)

            let rawDispatchID = firstString(in: dict, keys: ["dispatchId", "dispatchID", "dispatch_id", "id"])
            let sanitizedDispatchID = sanitizeDispatchID(rawDispatchID) ?? (state.isRunningOrFailed ? "orca-\(index)" : "")

            let taskID = sanitizeSimpleID(
                firstString(in: dict, keys: ["taskId", "taskID", "task_id"])
                    ?? nestedString(in: dict, path: ["task", "id"])
            )
            let runID = sanitizeSimpleID(
                firstString(in: dict, keys: ["runId", "runID", "run_id"])
                    ?? nestedString(in: dict, path: ["projection", "runId"])
            )

            let directTitle = firstString(in: dict, keys: ["title", "taskTitle", "task_title"])
                ?? nestedString(in: dict, path: ["task", "title"])
                ?? nestedString(in: dict, path: ["projection", "taskTitle"])
                ?? nestedString(in: dict, path: ["projection", "title"])

            let mappedTitle = (rawDispatchID.flatMap { taskTitlesByDispatchID[$0] })
                ?? (taskID.flatMap { taskTitlesByID[$0] })

            let safeTitle = sanitizeTitle(directTitle) ?? sanitizeTitle(mappedTitle)

            let focusResolution = resolveFocusMetadata(
                from: dict,
                dispatchID: sanitizedDispatchID,
                state: state
            )

            let item = OrcaTaskStatusItem(
                dispatchID: sanitizedDispatchID,
                state: state,
                title: safeTitle,
                canFocusWindow: focusResolution.canFocus
            )

            parsed.append(
                ParsedOrcaWorkerEntry(
                    item: item,
                    taskID: taskID,
                    runID: runID,
                    focusTarget: focusResolution.target
                )
            )
        }

        return parsed
    }

    /// Extracts human task titles from `orca orchestration task-list --run <id> --json`.
    public static func parseTaskTitles(
        _ data: Data
    ) -> (byTaskID: [String: String], byDispatchID: [String: String]) {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return ([:], [:])
        }

        let tasksArray: [[String: Any]] = {
            if let arr = root as? [[String: Any]] {
                return arr
            }
            guard let obj = root as? [String: Any] else { return [] }
            if let ok = obj["ok"] as? Bool, !ok {
                return []
            }
            if let result = obj["result"] as? [String: Any],
               let arr = result["tasks"] as? [[String: Any]] {
                return arr
            }
            if let arr = obj["tasks"] as? [[String: Any]] {
                return arr
            }
            return []
        }()

        var byTaskID: [String: String] = [:]
        var byDispatchID: [String: String] = [:]

        for task in tasksArray {
            guard let safeTitle = sanitizeTitle(firstString(in: task, keys: ["title", "name"])) else {
                continue
            }
            if let taskID = sanitizeSimpleID(firstString(in: task, keys: ["id", "taskId", "taskID"])) {
                byTaskID[taskID] = safeTitle
            }
            if let dispatchID = sanitizeDispatchID(firstString(in: task, keys: ["dispatchId", "dispatchID"])) {
                byDispatchID[dispatchID] = safeTitle
            }
        }

        return (byTaskID, byDispatchID)
    }

    /// Condenses newest-first parsed worker entries into the companion snapshot:
    /// surfaces active (`working`/`waiting`) rows plus current-run `failed` rows, or one quiet `idle` row when settled.
    public static func buildWireSnapshot(
        from entries: [ParsedOrcaWorkerEntry],
        maxRows: Int = 6
    ) -> OrcaTaskStatusSnapshot {
        let cap = max(1, maxRows)
        guard !entries.isEmpty else {
            return OrcaTaskStatusSnapshot(
                isOrcaRunning: true,
                tasks: [OrcaTaskStatusItem(dispatchID: "", state: .idle, title: nil, canFocusWindow: false)]
            )
        }

        let latestRunID = entries.first?.runID
        var settledTaskIDs = Set<String>()
        var settledWorkspaces = Set<String>()
        var highlighted: [OrcaTaskStatusItem] = []

        for entry in entries {
            switch entry.item.state {
            case .working, .waiting:
                highlighted.append(entry.item)
                if let tid = entry.taskID {
                    settledTaskIDs.insert(tid)
                }
                if let ws = entry.focusTarget?.workspaceSelector {
                    settledWorkspaces.insert(ws)
                }

            case .failed:
                let belongsToCurrentScope: Bool = {
                    if let latestRunID, let entryRunID = entry.runID {
                        return entryRunID == latestRunID
                    }
                    if let tid = entry.taskID, settledTaskIDs.contains(tid) {
                        return false
                    }
                    if let ws = entry.focusTarget?.workspaceSelector, settledWorkspaces.contains(ws) {
                        return false
                    }
                    return true
                }()
                if belongsToCurrentScope {
                    highlighted.append(entry.item)
                }

            case .idle:
                if let tid = entry.taskID {
                    settledTaskIDs.insert(tid)
                }
                if let ws = entry.focusTarget?.workspaceSelector {
                    settledWorkspaces.insert(ws)
                }
            }

            if highlighted.count >= cap {
                break
            }
        }

        if !highlighted.isEmpty {
            return OrcaTaskStatusSnapshot(isOrcaRunning: true, tasks: highlighted)
        }

        let latestIdleTitle = entries.first?.item.title
        let latestDispatchID = entries.first?.item.dispatchID ?? ""
        return OrcaTaskStatusSnapshot(
            isOrcaRunning: true,
            tasks: [
                OrcaTaskStatusItem(
                    dispatchID: latestDispatchID,
                    state: .idle,
                    title: latestIdleTitle,
                    canFocusWindow: false
                )
            ]
        )
    }

    // MARK: - Sanitization

    /// Drops multi-line transcripts, environment variable dumps, pairing codes, bearer/API/daemon tokens,
    /// and high-entropy opaque secret strings so only concise human task titles survive.
    public static func sanitizeTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxSafeTitleLength else {
            return nil
        }

        // Drop multi-line bodies, ANSI escapes, or NUL/control characters (terminal transcripts & prompts).
        for scalar in trimmed.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\0" || scalar.value == 0x1B {
                return nil
            }
            if scalar.value < 0x20 && scalar != "\t" {
                return nil
            }
        }

        let normalized = trimmed.replacingOccurrences(of: "\t", with: " ")

        if normalized.contains("```") || normalized.contains("=== ") || normalized.hasPrefix("$ ") {
            return nil
        }

        let lower = normalized.lowercased()
        let forbiddenSubstrings = [
            "orca://",
            "bearer ",
            "daemon_token",
            "daemontoken",
            "auth_token",
            "authtoken",
            "pairing_code",
            "pairingcode",
            "pairing code",
            "pair code",
            "api_key",
            "apikey",
            "client_secret",
            "private_key",
            "-----begin "
        ]
        for marker in forbiddenSubstrings where lower.contains(marker) {
            return nil
        }

        // Drop environment variable assignments such as ORCA_TOKEN=... or OPENAI_API_KEY=...
        if normalized.range(of: #"\b[A-Z][A-Z0-9_]{2,}=\S+"#, options: .regularExpression) != nil {
            return nil
        }

        // Drop key=value or key: value secret assignments.
        if lower.range(
            of: #"\b(token|secret|password|passwd|pin|pair|code)\s*[:=]\s*\S+"#,
            options: .regularExpression
        ) != nil {
            return nil
        }

        // Drop JWTs (eyJ...header.payload).
        if normalized.range(
            of: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
            options: .regularExpression
        ) != nil {
            return nil
        }

        // Inspect individual whitespace-delimited tokens for secret prefixes or >=32-char opaque blobs.
        let secretPrefixes = [
            "sk-", "ghp_", "gho_", "ghs_", "github_pat_",
            "xoxb-", "xoxp-", "orca_tok_", "dt_", "tok_", "sec_"
        ]
        for word in normalized.split(whereSeparator: \.isWhitespace) {
            let cleanWord = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),;[]{}<>"))
            let lowerWord = cleanWord.lowercased()
            for prefix in secretPrefixes where lowerWord.hasPrefix(prefix) && cleanWord.count >= prefix.count + 6 {
                return nil
            }
            if cleanWord.count >= 32,
               cleanWord.unicodeScalars.allSatisfy({ scalar in
                   CharacterSet.alphanumerics.contains(scalar)
                       || scalar == "+" || scalar == "/" || scalar == "="
                       || scalar == "_" || scalar == "-"
               }) {
                return nil
            }
        }

        return normalized
    }

    public static func sanitizeDispatchID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else {
            return nil
        }
        guard trimmed.unicodeScalars.allSatisfy({ scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "."
        }) else {
            return nil
        }
        let lower = trimmed.lowercased()
        let forbiddenPrefixes = ["sk-", "ghp_", "gho_", "ghs_", "github_pat_", "orca_tok_", "tok_", "sec_", "dt_", "eyj"]
        for prefix in forbiddenPrefixes where lower.hasPrefix(prefix) {
            return nil
        }
        // Reject long contiguous opaque hex/token strings while allowing ctx_<hex> and standard 36-char UUIDs.
        if !trimmed.contains("-") && !lower.hasPrefix("ctx_") && !lower.hasPrefix("dispatch_") && trimmed.count >= 32 {
            return nil
        }
        return trimmed
    }

    private static func sanitizeSimpleID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 80,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "."
              }) else {
            return nil
        }
        return trimmed
    }

    // MARK: - Internal Extraction Helpers

    private static func extractWorkerDictionaries(from root: Any) throws -> [[String: Any]] {
        if let array = root as? [[String: Any]] {
            return array
        }
        guard let obj = root as? [String: Any] else {
            throw OrcaWorkerListParseError.invalidJSON
        }
        if let ok = obj["ok"] as? Bool, !ok {
            throw OrcaWorkerListParseError.runtimeUnavailable
        }
        if let result = obj["result"] as? [String: Any] {
            if let workers = result["workers"] as? [[String: Any]] {
                return workers
            }
            if let items = result["items"] as? [[String: Any]] {
                return items
            }
        }
        if let workers = obj["workers"] as? [[String: Any]] {
            return workers
        }
        if let items = obj["items"] as? [[String: Any]] {
            return items
        }
        throw OrcaWorkerListParseError.invalidJSON
    }

    private static func classifyState(from dict: [String: Any]) -> OrcaTaskState {
        let primaryState = normalizedToken(
            firstString(in: dict, keys: ["state", "workerState", "worker_state"])
                ?? nestedString(in: dict, path: ["projection", "stage", "worker"])
        )
        let dispatchStatus = normalizedToken(
            firstString(in: dict, keys: ["status", "dispatchStatus", "dispatch_status"])
                ?? nestedString(in: dict, path: ["projection", "stage", "dispatch"])
        )
        let outcome = normalizedToken(
            firstString(in: dict, keys: ["outcome"])
                ?? nestedString(in: dict, path: ["projection", "outcome"])
        )
        let activity = normalizedToken(
            firstString(in: dict, keys: ["activity"])
                ?? nestedString(in: dict, path: ["projection", "stage", "activity"])
        )
        let stageDetail = normalizedToken(
            nestedString(in: dict, path: ["projection", "stage", "detail"])
        )
        let liveness = normalizedToken(
            firstString(in: dict, keys: ["liveness"])
                ?? nestedString(in: dict, path: ["liveness", "verdict"])
                ?? nestedString(in: dict, path: ["projection", "liveness", "verdict"])
        )

        // 1. Failed takes top priority (e.g. state="stopped" + outcome="failed", or state="failed").
        if let outcome, failedKeywords.contains(outcome) {
            return .failed
        }
        if let primaryState, failedKeywords.contains(primaryState) {
            return .failed
        }
        if let dispatchStatus, failedKeywords.contains(dispatchStatus) {
            return .failed
        }

        // 2. Settled / idle workers (before inspecting generic attention flags like "unverifiable").
        if let primaryState, settledIdleKeywords.contains(primaryState) {
            return .idle
        }
        if let outcome, settledIdleKeywords.contains(outcome) {
            return .idle
        }
        if let dispatchStatus, settledIdleKeywords.contains(dispatchStatus) {
            return .idle
        }

        // 3. Waiting for coordinator/user input, approval, or blocked attention.
        if let primaryState, waitingKeywords.contains(primaryState) {
            return .waiting
        }
        if let dispatchStatus, waitingKeywords.contains(dispatchStatus) {
            return .waiting
        }
        if let activity, waitingKeywords.contains(activity) {
            return .waiting
        }
        if let stageDetail, waitingKeywords.contains(stageDetail) {
            return .waiting
        }
        if indicatesWaitingAttention(dict["attention"])
            || indicatesWaitingAttention((dict["projection"] as? [String: Any])?["attention"]) {
            return .waiting
        }

        // 4. Working (includes Orca's active `state: "ready", outcome: "in_progress"` shape).
        if let primaryState, workingKeywords.contains(primaryState) {
            return .working
        }
        if outcome == "in_progress" {
            return .working
        }
        if let dispatchStatus, workingKeywords.contains(dispatchStatus) {
            return .working
        }
        if let activity, workingKeywords.contains(activity) || activity == "input_accepted" || activity == "streaming" {
            return .working
        }
        if primaryState == "ready" && liveness == "live" {
            return .working
        }

        return .idle
    }

    private static func indicatesWaitingAttention(_ raw: Any?) -> Bool {
        guard let raw else { return false }
        if let flag = raw as? Bool {
            return flag
        }
        if let text = raw as? String {
            return tokenIndicatesWaiting(text)
        }
        if let list = raw as? [Any] {
            for element in list {
                if let text = element as? String, tokenIndicatesWaiting(text) {
                    return true
                }
            }
            return false
        }
        if let obj = raw as? [String: Any] {
            if let requiresAction = obj["requiresAction"] as? Bool, requiresAction {
                return true
            }
            if let categories = obj["categories"] as? [Any] {
                for cat in categories {
                    if let text = cat as? String, tokenIndicatesWaiting(text) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func tokenIndicatesWaiting(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty, lower != "unverifiable", lower != "failure", lower != "failed", lower != "none" else {
            return false
        }
        let needles = [
            "wait", "block", "question", "escalat", "input", "approv", "permission", "prompt", "human", "pause"
        ]
        return needles.contains { lower.contains($0) }
    }

    private static func resolveFocusMetadata(
        from dict: [String: Any],
        dispatchID: String,
        state: OrcaTaskState
    ) -> (canFocus: Bool, target: OrcaFocusTarget?) {
        guard state.isRunningOrFailed else {
            return (false, nil)
        }

        let host = normalizedToken(firstString(in: dict, keys: ["host"]))
        if let host, host != "local" {
            let explicit = (dict["canFocusWindow"] as? Bool) ?? false
            return (explicit, nil)
        }

        let terminalState = normalizedToken(
            firstString(in: dict, keys: ["terminalState", "terminal_state"])
                ?? nestedString(in: dict, path: ["resource", "releaseState"])
        )
        let isTerminalReleased = terminalState.map { releasedTerminalKeywords.contains($0) } ?? false

        let rawTerminal = firstString(in: dict, keys: ["terminal", "agentTerminalHandle", "terminalHandle"])
            ?? nestedString(in: dict, path: ["resource", "terminalHandle"])
        let validTerminal: String? = {
            guard !isTerminalReleased,
                  let handle = sanitizeSimpleID(rawTerminal),
                  (try? OrcaCommandBuilder.terminalSwitchCommand(executablePath: "/usr/local/bin/orca", terminalHandle: handle)) != nil else {
                return nil
            }
            return handle
        }()

        let rawWorkspace = firstString(in: dict, keys: ["workspace", "worktreeId", "worktree"])
            ?? nestedString(in: dict, path: ["resource", "worktreeId"])
            ?? nestedString(in: dict, path: ["projection", "workspace", "id"])

        let (workspaceSelector, workspaceHint): (String?, String?) = {
            guard let raw = rawWorkspace?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  !raw.contains("\n"),
                  !raw.contains("\r"),
                  !raw.contains("\0") else {
                return (nil, nil)
            }
            let selector: String
            if raw.hasPrefix("id:") || raw.hasPrefix("path:") || raw.hasPrefix("name:") || raw.hasPrefix("branch:") {
                selector = raw
            } else if raw.contains("::") {
                selector = "id:\(raw)"
            } else if raw.hasPrefix("/") {
                selector = "path:\(raw)"
            } else {
                selector = raw
            }

            let pathPortion: String = {
                if let sep = raw.range(of: "::") {
                    return String(raw[sep.upperBound...])
                }
                return raw
            }()
            let base = URL(fileURLWithPath: pathPortion).lastPathComponent
            let hint = base.isEmpty ? nil : base
            return (selector, hint)
        }()

        let inferredFocusable = (validTerminal != nil) || (workspaceSelector != nil)
        let canFocus = (dict["canFocusWindow"] as? Bool) ?? inferredFocusable
        guard canFocus, !dispatchID.isEmpty else {
            return (false, nil)
        }

        let target = OrcaFocusTarget(
            dispatchID: dispatchID,
            state: state,
            terminalHandle: validTerminal,
            workspaceSelector: workspaceSelector,
            workspaceHint: workspaceHint
        )
        return (true, target)
    }

    private static func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func nestedString(in dict: [String: Any], path: [String]) -> String? {
        var current: Any? = dict
        for segment in path {
            guard let map = current as? [String: Any] else { return nil }
            current = map[segment]
        }
        guard let str = current as? String,
              !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return str
    }

    private static func normalizedToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
