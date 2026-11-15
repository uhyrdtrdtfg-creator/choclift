import Foundation

public enum CaptureCompanionActionID: String, CaseIterable, Equatable, Hashable, Sendable {
    case windowToClipboard = "capture.window_to_clipboard"
    case screenToDesktop = "capture.screen_to_desktop"

    public var companionAction: CompanionAction {
        switch self {
        case .windowToClipboard:
            return CompanionAction(
                id: rawValue,
                titleZh: "窗口截图到剪贴板",
                titleEn: "Window to Clipboard",
                sfSymbol: "camera.metering.spot"
            )
        case .screenToDesktop:
            return CompanionAction(
                id: rawValue,
                titleZh: "全屏截图到桌面",
                titleEn: "Screen to Desktop",
                sfSymbol: "camera"
            )
        }
    }
}

extension CompanionActionCatalog {
    public static let capturePack: [CompanionAction] = CaptureCompanionActionID.allCases.map(\.companionAction)
}

public enum CaptureActionFailure: Error, Equatable, Sendable {
    case unknownAction(String)
    case frontWindowUnavailable
    case desktopDirectoryUnavailable
    case launchFailed(String)
    case timedOut
    case nonZeroExit(status: Int32, stderr: String)

    public func message(in language: AppLanguage = .system) -> String {
        switch self {
        case .unknownAction(let id):
            return L10n.tr(
                "不支持的截图操作：\(id)",
                "Unsupported capture action: \(id)",
                language: language
            )
        case .frontWindowUnavailable:
            return L10n.tr(
                "未找到可截图的前台窗口",
                "Could not resolve a front window to capture",
                language: language
            )
        case .desktopDirectoryUnavailable:
            return L10n.tr(
                "桌面文件夹不存在",
                "Desktop folder does not exist",
                language: language
            )
        case .launchFailed(let detail):
            let clean = CaptureCommandPlan.sanitizedStderr(detail)
            if clean.isEmpty {
                return L10n.tr(
                    "无法启动系统截图工具 screencapture",
                    "Could not launch /usr/sbin/screencapture",
                    language: language
                )
            }
            return L10n.tr(
                "无法启动系统截图工具：\(clean)",
                "Could not launch /usr/sbin/screencapture: \(clean)",
                language: language
            )
        case .timedOut:
            return L10n.tr(
                "截图超时（超过 3 秒），请检查系统设置中的「屏幕录制」权限",
                "Screen capture timed out after 3 seconds; Screen Recording permission may be required",
                language: language
            )
        case .nonZeroExit(let status, let stderr):
            let clean = CaptureCommandPlan.sanitizedStderr(stderr)
            if clean.isEmpty {
                return L10n.tr(
                    "截图失败（退出码 \(status)）。可能需要授予「屏幕录制」权限（系统设置 → 隐私与安全性 → 屏幕录制）。",
                    "Screen capture failed (exit \(status)). Screen Recording permission may be required in System Settings → Privacy & Security → Screen Recording.",
                    language: language
                )
            }
            return L10n.tr(
                "截图失败（退出码 \(status)）：\(clean)。可能需要授予「屏幕录制」权限（系统设置 → 隐私与安全性 → 屏幕录制）。",
                "Screen capture failed (exit \(status)): \(clean). Screen Recording permission may be required in System Settings → Privacy & Security → Screen Recording.",
                language: language
            )
        }
    }
}

public struct CaptureCommandSpec: Equatable, Hashable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var outputFileURL: URL?

    public init(
        executablePath: String = CaptureCommandPlan.screencaptureExecutablePath,
        arguments: [String],
        outputFileURL: URL? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.outputFileURL = outputFileURL
    }

    public var executableURL: URL {
        URL(fileURLWithPath: executablePath)
    }
}

public struct CaptureProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stderr: String = "", timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public struct CaptureWindowCandidate: Equatable, Hashable, Sendable {
    public var windowID: UInt32
    public var ownerPID: Int32
    public var layer: Int
    public var alpha: Double
    public var bounds: WindowQuartzRect
    public var isOnScreen: Bool

    public init(
        windowID: UInt32,
        ownerPID: Int32,
        layer: Int = 0,
        alpha: Double = 1.0,
        bounds: WindowQuartzRect,
        isOnScreen: Bool = true
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
        self.isOnScreen = isOnScreen
    }
}

public enum CaptureFrontWindowResolver {
    public static let minimumWindowDimension: Double = 24.0
    public static let frameMatchTolerance: Double = 8.0

    public static func resolveWindowID(
        candidates: [CaptureWindowCandidate],
        primaryPID: Int32?,
        primaryFocusedFrame: WindowQuartzRect? = nil,
        fallbackPID: Int32? = nil,
        fallbackFocusedFrame: WindowQuartzRect? = nil,
        eligibleOwnerPIDs: Set<Int32> = [],
        selfPID: Int32
    ) -> UInt32? {
        let capturable = candidates.filter { candidate in
            candidate.windowID > 0
                && candidate.ownerPID > 0
                && candidate.ownerPID != selfPID
                && candidate.layer == 0
                && candidate.alpha > 0.01
                && candidate.isOnScreen
                && candidate.bounds.width >= minimumWindowDimension
                && candidate.bounds.height >= minimumWindowDimension
        }
        guard !capturable.isEmpty else { return nil }

        if let primaryPID, primaryPID > 0, primaryPID != selfPID {
            if let match = matchWindowID(
                in: capturable,
                ownerPID: primaryPID,
                focusedFrame: primaryFocusedFrame
            ) {
                return match
            }
        }

        if let fallbackPID, fallbackPID > 0, fallbackPID != selfPID, fallbackPID != primaryPID {
            if let match = matchWindowID(
                in: capturable,
                ownerPID: fallbackPID,
                focusedFrame: fallbackFocusedFrame
            ) {
                return match
            }
        }

        if !eligibleOwnerPIDs.isEmpty,
           let topmostEligible = capturable.first(where: { eligibleOwnerPIDs.contains($0.ownerPID) }) {
            return topmostEligible.windowID
        }

        return nil
    }

    private static func matchWindowID(
        in capturable: [CaptureWindowCandidate],
        ownerPID: Int32,
        focusedFrame: WindowQuartzRect?
    ) -> UInt32? {
        let owned = capturable.filter { $0.ownerPID == ownerPID }
        guard !owned.isEmpty else { return nil }

        if let focusedFrame,
           let exact = owned.first(where: { framesApproximatelyMatch($0.bounds, focusedFrame) }) {
            return exact.windowID
        }
        return owned.first?.windowID
    }

    private static func framesApproximatelyMatch(_ lhs: WindowQuartzRect, _ rhs: WindowQuartzRect) -> Bool {
        abs(lhs.x - rhs.x) <= frameMatchTolerance
            && abs(lhs.y - rhs.y) <= frameMatchTolerance
            && abs(lhs.width - rhs.width) <= frameMatchTolerance
            && abs(lhs.height - rhs.height) <= frameMatchTolerance
    }
}

public enum CaptureCommandPlan {
    public static let screencaptureExecutablePath = "/usr/sbin/screencapture"
    public static let defaultTimeoutSeconds: TimeInterval = 3.0
    public static let fileNamePrefix = "Choclift-"
    public static let fileExtension = "png"

    public static var screencaptureExecutableURL: URL {
        URL(fileURLWithPath: screencaptureExecutablePath)
    }

    public static func timestampString(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    public static func desktopFileName(
        for date: Date,
        timeZone: TimeZone = .current,
        existingFileNames: Set<String> = []
    ) -> String {
        let dummyDesktop = URL(fileURLWithPath: "/Desktop", isDirectory: true)
        return resolveDesktopOutputURL(
            desktopDirectoryURL: dummyDesktop,
            date: date,
            timeZone: timeZone,
            fileExists: { existingFileNames.contains($0.lastPathComponent) }
        ).lastPathComponent
    }

    public static func resolveDesktopOutputURL(
        desktopDirectoryURL: URL,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let stem = "\(fileNamePrefix)\(timestampString(for: date, timeZone: timeZone))"
        let initialURL = desktopDirectoryURL.appendingPathComponent("\(stem).\(fileExtension)", isDirectory: false)
        if !fileExists(initialURL) {
            return initialURL
        }

        for suffix in 2...9999 {
            let candidateURL = desktopDirectoryURL.appendingPathComponent(
                "\(stem)-\(suffix).\(fileExtension)",
                isDirectory: false
            )
            if !fileExists(candidateURL) {
                return candidateURL
            }
        }

        let token = UUID().uuidString.lowercased().prefix(8)
        return desktopDirectoryURL.appendingPathComponent(
            "\(stem)-\(token).\(fileExtension)",
            isDirectory: false
        )
    }

    public static func windowToClipboardArguments(windowID: UInt32?) -> Result<[String], CaptureActionFailure> {
        guard let windowID, windowID > 0 else {
            return .failure(.frontWindowUnavailable)
        }
        return .success(["-l", String(windowID), "-c"])
    }

    public static func screenToDesktopArguments(outputFileURL: URL) -> [String] {
        [outputFileURL.path]
    }

    public static func buildCommandSpec(
        for id: String,
        frontWindowID: () -> UInt32?,
        desktopDirectoryURL: URL,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Result<CaptureCommandSpec, CaptureActionFailure> {
        guard let action = CaptureCompanionActionID(rawValue: id) else {
            return .failure(.unknownAction(id))
        }

        switch action {
        case .windowToClipboard:
            switch windowToClipboardArguments(windowID: frontWindowID()) {
            case .failure(let error):
                return .failure(error)
            case .success(let arguments):
                return .success(
                    CaptureCommandSpec(
                        executablePath: screencaptureExecutablePath,
                        arguments: arguments,
                        outputFileURL: nil
                    )
                )
            }

        case .screenToDesktop:
            let outputURL = resolveDesktopOutputURL(
                desktopDirectoryURL: desktopDirectoryURL,
                date: now,
                timeZone: timeZone,
                fileExists: fileExists
            )
            return .success(
                CaptureCommandSpec(
                    executablePath: screencaptureExecutablePath,
                    arguments: screenToDesktopArguments(outputFileURL: outputURL),
                    outputFileURL: outputURL
                )
            )
        }
    }

    public static func execute(
        id: String,
        language: AppLanguage = .system,
        frontWindowID: () -> UInt32?,
        desktopDirectoryURL: () -> Result<URL, CaptureActionFailure>,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        runProcess: (CaptureCommandSpec) -> Result<CaptureProcessResult, CaptureActionFailure>
    ) -> (success: Bool, message: String) {
        guard let action = CaptureCompanionActionID(rawValue: id) else {
            return (false, CaptureActionFailure.unknownAction(id).message(in: language))
        }

        let spec: CaptureCommandSpec
        switch action {
        case .windowToClipboard:
            switch windowToClipboardArguments(windowID: frontWindowID()) {
            case .failure(let failure):
                return (false, failure.message(in: language))
            case .success(let arguments):
                spec = CaptureCommandSpec(
                    executablePath: screencaptureExecutablePath,
                    arguments: arguments,
                    outputFileURL: nil
                )
            }

        case .screenToDesktop:
            switch desktopDirectoryURL() {
            case .failure(let failure):
                return (false, failure.message(in: language))
            case .success(let desktopDir):
                let outputURL = resolveDesktopOutputURL(
                    desktopDirectoryURL: desktopDir,
                    date: now,
                    timeZone: timeZone,
                    fileExists: fileExists
                )
                spec = CaptureCommandSpec(
                    executablePath: screencaptureExecutablePath,
                    arguments: screenToDesktopArguments(outputFileURL: outputURL),
                    outputFileURL: outputURL
                )
            }
        }

        let processOutcome: CaptureProcessResult
        switch runProcess(spec) {
        case .failure(let failure):
            return (false, failure.message(in: language))
        case .success(let result):
            processOutcome = result
        }

        if processOutcome.timedOut {
            return (false, CaptureActionFailure.timedOut.message(in: language))
        }
        if processOutcome.exitCode != 0 {
            return (
                false,
                CaptureActionFailure.nonZeroExit(
                    status: processOutcome.exitCode,
                    stderr: processOutcome.stderr
                ).message(in: language)
            )
        }

        switch action {
        case .windowToClipboard:
            return (
                true,
                L10n.tr(
                    "已将前台窗口截图复制到剪贴板",
                    "Copied front window screenshot to clipboard",
                    language: language
                )
            )
        case .screenToDesktop:
            let fileName = spec.outputFileURL?.lastPathComponent ?? ""
            return (
                true,
                L10n.tr(
                    "已保存全屏截图到桌面：\(fileName)",
                    "Saved screen capture to Desktop: \(fileName)",
                    language: language
                )
            )
        }
    }

    public static func sanitizedStderr(_ raw: String, maxCharacters: Int = 240) -> String {
        let collapsed = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxCharacters else {
            return collapsed
        }
        return String(collapsed.prefix(maxCharacters)) + "…"
    }
}
