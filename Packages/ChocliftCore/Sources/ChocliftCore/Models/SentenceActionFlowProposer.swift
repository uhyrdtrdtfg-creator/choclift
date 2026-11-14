#if os(macOS)
import Foundation

// MARK: - Mac-Only Sentence -> Proposed Action Flow Draft & Confirmation Engine

public struct ActionFlowProposalSnippetSummary: Equatable, Hashable, Sendable {
    public let id: UUID
    public let title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct ActionFlowProposalCatalogContext: Equatable, Sendable {
    public var installedApps: [InstalledAppSummary]
    public var installedShortcuts: [InstalledShortcutSummary]
    public var snippets: [ActionFlowProposalSnippetSummary]
    public var language: AppLanguage

    public init(
        installedApps: [InstalledAppSummary] = [],
        installedShortcuts: [InstalledShortcutSummary] = [],
        snippets: [ActionFlowProposalSnippetSummary] = [],
        language: AppLanguage = .system
    ) {
        self.installedApps = installedApps
        self.installedShortcuts = installedShortcuts
        self.snippets = snippets
        self.language = language
    }
}

public struct ActionFlowDraft: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceSentence: String
    public let originDeviceName: String
    public var flow: ActionFlow

    public init(
        id: UUID = UUID(),
        sourceSentence: String,
        originDeviceName: String = "Mac Studio",
        flow: ActionFlow
    ) {
        self.id = id
        self.sourceSentence = sourceSentence
        self.originDeviceName = originDeviceName
        self.flow = flow
    }
}

public enum ActionFlowProposalError: Error, Equatable, Sendable, LocalizedError {
    case emptySentence
    case missingAPIKey
    case httpStatus(statusCode: Int, detail: String?)
    case transportError(String)
    case responseDecodeFailed(String)
    case draftDecodeFailed(String)
    case unknownStepType(String)
    case invalidStep(index: Int, reason: String)
    case emptySteps

    public var errorDescription: String? {
        localizedDescription(in: .system)
    }

    public func localizedDescription(in language: AppLanguage) -> String {
        switch self {
        case .emptySentence:
            return L10n.tr(
                "请输入要转换为动作流的一句话描述。",
                "Enter a sentence describing the Action Flow you want to create.",
                language: language
            )

        case .missingAPIKey:
            return L10n.tr(
                "未找到 XAI_API_KEY。请在 Mac 环境变量或本地 git 忽略文件（.env / .xai_api_key）中配置 XAI_API_KEY，当前未创建任何动作流。",
                "XAI_API_KEY is missing. Set XAI_API_KEY in the Mac environment or a git-ignored local .env / .xai_api_key file — no flow was created.",
                language: language
            )

        case .httpStatus(let statusCode, let detail):
            let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                return L10n.tr(
                    "模型请求失败（HTTP \(statusCode)）。",
                    "Model request failed (HTTP \(statusCode)).",
                    language: language
                )
            }
            return L10n.tr(
                "模型请求失败（HTTP \(statusCode)）：\(trimmed)",
                "Model request failed (HTTP \(statusCode)): \(trimmed)",
                language: language
            )

        case .transportError(let detail):
            return L10n.tr(
                "连接 xAI 网络失败：\(detail)",
                "Network error contacting xAI: \(detail)",
                language: language
            )

        case .responseDecodeFailed(let detail):
            return L10n.tr(
                "解析模型响应失败：\(detail)",
                "Failed to decode model response: \(detail)",
                language: language
            )

        case .draftDecodeFailed(let detail):
            return L10n.tr(
                "解析动作流 JSON 草稿失败：\(detail)",
                "Failed to decode Action Flow draft JSON: \(detail)",
                language: language
            )

        case .unknownStepType(let rawType):
            return L10n.tr(
                "模型返回了不支持的步骤类型「\(rawType)」，已拒绝生成草稿。",
                "Unknown step type \"\(rawType)\" is not supported and cannot become a runnable step.",
                language: language
            )

        case .invalidStep(let index, let reason):
            return L10n.tr(
                "第 \(index + 1) 步参数无效：\(reason)",
                "Proposed step \(index + 1) is invalid: \(reason)",
                language: language
            )

        case .emptySteps:
            return L10n.tr(
                "模型未返回任何可执行的动作流步骤。",
                "The model returned no executable Action Flow steps.",
                language: language
            )
        }
    }
}

// MARK: - System Prompt Listing Only Existing ActionFlowStepKind Cases

public enum ActionFlowSystemPromptBuilder {
    public static let allowedStepTypeTags: [String] = [
        "launch_or_activate_app",
        "wait_for_app_frontmost",
        "delay",
        "system_action",
        "open_website",
        "run_shortcut",
        "insert_snippet"
    ]

    public static func makeSystemPrompt(context: ActionFlowProposalCatalogContext = .init()) -> String {
        let quickActionTags = SystemQuickAction.allCases.map(\.rawValue).joined(separator: ", ")

        var lines: [String] = [
            "You convert a user's single sentence into a macOS Choclift ActionFlow draft.",
            "Return JSON ONLY: a single valid JSON object with no markdown fences and no commentary.",
            "",
            "Top-level JSON schema:",
            "{",
            "  \"name\": \"<short flow title>\",",
            "  \"emoji\": \"<single emoji, e.g. ⚡️>\",",
            "  \"backgroundHex\": \"<hex color, e.g. #ECFAFE>\",",
            "  \"steps\": [ <non-empty ordered array of step objects> ]",
            "}",
            "",
            "Allowed step \"type\" values — use ONLY these 7 existing ActionFlowStepKind cases and NEVER invent any other step type:",
            "1. \"launch_or_activate_app\" (launch app): {\"type\": \"launch_or_activate_app\", \"bundleIdentifier\": \"<macOS bundle ID>\", \"appName\": \"<app display name>\"}",
            "2. \"wait_for_app_frontmost\" (wait until frontmost): {\"type\": \"wait_for_app_frontmost\", \"bundleIdentifier\": \"<bundle ID or empty string to follow previous app>\", \"appName\": \"<optional app name>\", \"timeoutSeconds\": 3.0}",
            "3. \"delay\" (delay): {\"type\": \"delay\", \"seconds\": <number from 0.05 to 10.0>}",
            "4. \"system_action\" (system action): {\"type\": \"system_action\", \"action\": \"<one of: \(quickActionTags)>\", \"targetBundleIdentifier\": \"<optional bundle ID>\", \"targetAppName\": \"<optional app name>\"}",
            "5. \"open_website\" (open website): {\"type\": \"open_website\", \"url\": \"<https://...>\", \"title\": \"<optional title>\", \"switchExistingTab\": true}",
            "6. \"run_shortcut\" (run shortcut): {\"type\": \"run_shortcut\", \"shortcutName\": \"<exact macOS Shortcut name>\"}",
            "7. \"insert_snippet\" (insert snippet): {\"type\": \"insert_snippet\", \"snippetID\": \"<UUID string>\", \"titleSnapshot\": \"<optional snippet title>\"}",
            "",
            "Common macOS bundle identifiers: Safari=com.apple.Safari, Finder=com.apple.finder, Notes=com.apple.Notes, Terminal=com.apple.Terminal, Xcode=com.apple.dt.Xcode, Mail=com.apple.mail, Calendar=com.apple.iCal, Reminders=com.apple.reminders, Music=com.apple.Music, Messages=com.apple.MobileSMS, Preview=com.apple.Preview, Calculator=com.apple.calculator, System Settings=com.apple.systempreferences."
        ]

        if !context.installedApps.isEmpty {
            let appList = context.installedApps
                .prefix(80)
                .map { "\($0.appName)=\($0.bundleIdentifier)" }
                .joined(separator: "; ")
            lines.append("Installed Mac apps: \(appList)")
        }

        if !context.installedShortcuts.isEmpty {
            let shortcutList = context.installedShortcuts
                .prefix(50)
                .map(\.name)
                .joined(separator: "; ")
            lines.append("Installed Mac shortcuts: \(shortcutList)")
        }

        if !context.snippets.isEmpty {
            let snippetList = context.snippets
                .prefix(40)
                .map { "\($0.title)=\($0.id.uuidString)" }
                .joined(separator: "; ")
            lines.append("Saved text snippets (title=UUID): \(snippetList)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Strict Draft JSON Decoder (Unknown Step Types Fail Visibly)

public enum ActionFlowDraftDecoder {
    private static let builtInAppBundleIdentifiersByLowerName: [String: (bundleID: String, appName: String)] = [
        "safari": ("com.apple.Safari", "Safari"),
        "finder": ("com.apple.finder", "Finder"),
        "notes": ("com.apple.Notes", "Notes"),
        "terminal": ("com.apple.Terminal", "Terminal"),
        "xcode": ("com.apple.dt.Xcode", "Xcode"),
        "mail": ("com.apple.mail", "Mail"),
        "calendar": ("com.apple.iCal", "Calendar"),
        "reminders": ("com.apple.reminders", "Reminders"),
        "music": ("com.apple.Music", "Music"),
        "messages": ("com.apple.MobileSMS", "Messages"),
        "preview": ("com.apple.Preview", "Preview"),
        "calculator": ("com.apple.calculator", "Calculator"),
        "system settings": ("com.apple.systempreferences", "System Settings")
    ]

    public static func decodeDraft(
        from jsonString: String,
        sourceSentence: String = "",
        originDeviceName: String = "Mac Studio",
        context: ActionFlowProposalCatalogContext = .init()
    ) throws -> ActionFlowDraft {
        let unwrapped = stripOptionalMarkdownCodeFence(jsonString)
        guard let data = unwrapped.data(using: .utf8) else {
            throw ActionFlowProposalError.draftDecodeFailed("Invalid UTF-8 text")
        }
        return try decodeDraft(
            from: data,
            sourceSentence: sourceSentence,
            originDeviceName: originDeviceName,
            context: context
        )
    }

    public static func decodeDraft(
        from data: Data,
        sourceSentence: String = "",
        originDeviceName: String = "Mac Studio",
        context: ActionFlowProposalCatalogContext = .init()
    ) throws -> ActionFlowDraft {
        let cleanedData: Data = {
            guard let rawText = String(data: data, encoding: .utf8) else { return data }
            let stripped = stripOptionalMarkdownCodeFence(rawText)
            return Data(stripped.utf8)
        }()

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: cleanedData, options: [])
        } catch {
            throw ActionFlowProposalError.draftDecodeFailed(error.localizedDescription)
        }

        guard let root = jsonObject as? [String: Any] else {
            throw ActionFlowProposalError.draftDecodeFailed("Top-level JSON value must be an object")
        }

        guard let rawSteps = root["steps"] as? [Any] else {
            throw ActionFlowProposalError.draftDecodeFailed("Missing required \"steps\" array")
        }

        guard !rawSteps.isEmpty else {
            throw ActionFlowProposalError.emptySteps
        }

        var decodedSteps: [ActionFlowStep] = []
        decodedSteps.reserveCapacity(rawSteps.count)

        for (index, element) in rawSteps.enumerated() {
            guard let stepDict = element as? [String: Any] else {
                throw ActionFlowProposalError.draftDecodeFailed("Step \(index + 1) must be a JSON object")
            }
            let step = try decodeSingleStep(stepDict, index: index, context: context)
            if case .unsupported(let rawType) = step.kind {
                throw ActionFlowProposalError.unknownStepType(rawType)
            }
            decodedSteps.append(step)
        }

        let rawName = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackSentenceTitle = String(sourceSentence.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let resolvedName: String = {
            if !rawName.isEmpty { return rawName }
            if !fallbackSentenceTitle.isEmpty { return fallbackSentenceTitle }
            return L10n.tr("AI 建议动作流", "Proposed Flow", language: context.language)
        }()

        let rawEmoji = (root["emoji"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedEmoji = rawEmoji.isEmpty ? "⚡️" : String(rawEmoji.prefix(2))

        let rawHex = (root["backgroundHex"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedHex = isValidHexColor(rawHex) ? rawHex.uppercased() : "#ECFAFE"

        let flow = ActionFlow(
            name: resolvedName,
            emoji: resolvedEmoji,
            backgroundHex: resolvedHex,
            steps: decodedSteps
        )

        return ActionFlowDraft(
            sourceSentence: sourceSentence,
            originDeviceName: originDeviceName,
            flow: flow
        )
    }

    private static func decodeSingleStep(
        _ stepDict: [String: Any],
        index: Int,
        context: ActionFlowProposalCatalogContext
    ) throws -> ActionFlowStep {
        let isEnabled = (stepDict["isEnabled"] as? Bool) ?? true
        let stepID: UUID = {
            if let idStr = stepDict["id"] as? String, let parsed = UUID(uuidString: idStr) {
                return parsed
            }
            return UUID()
        }()

        let kindDict: [String: Any]
        if let nestedKind = stepDict["kind"] as? [String: Any] {
            kindDict = nestedKind
        } else {
            kindDict = stepDict
        }

        guard let rawType = (kindDict["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawType.isEmpty else {
            throw ActionFlowProposalError.draftDecodeFailed("Step \(index + 1) is missing \"type\"")
        }

        switch rawType {
        case "launch_or_activate_app":
            let rawBundle = (kindDict["bundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawAppName = (kindDict["appName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawAppPath = (kindDict["appPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            var resolvedBundle = rawBundle
            var resolvedName = rawAppName
            var resolvedPath = (rawAppPath?.isEmpty == false) ? rawAppPath : nil

            if resolvedBundle.isEmpty && !rawAppName.isEmpty {
                if let installed = context.installedApps.first(where: {
                    $0.appName.caseInsensitiveCompare(rawAppName) == .orderedSame
                }) {
                    resolvedBundle = installed.bundleIdentifier
                    resolvedName = installed.appName
                    if resolvedPath == nil {
                        resolvedPath = installed.appPath
                    }
                } else if let builtIn = builtInAppBundleIdentifiersByLowerName[rawAppName.lowercased()] {
                    resolvedBundle = builtIn.bundleID
                    resolvedName = builtIn.appName
                }
            }

            guard !resolvedBundle.isEmpty else {
                throw ActionFlowProposalError.invalidStep(
                    index: index,
                    reason: "launch_or_activate_app requires a non-empty bundleIdentifier"
                )
            }

            if resolvedName.isEmpty {
                if let installed = context.installedApps.first(where: {
                    $0.bundleIdentifier.caseInsensitiveCompare(resolvedBundle) == .orderedSame
                }) {
                    resolvedName = installed.appName
                } else {
                    resolvedName = resolvedBundle
                }
            }

            return ActionFlowStep(
                id: stepID,
                kind: .launchOrActivateApp(
                    bundleIdentifier: resolvedBundle,
                    appName: resolvedName,
                    appPath: resolvedPath
                ),
                isEnabled: isEnabled
            )

        case "wait_for_app_frontmost":
            let bundleID = (kindDict["bundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawName = (kindDict["appName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanName = (rawName?.isEmpty == false) ? rawName : nil

            let timeout: Double
            if let rawTimeoutObj = kindDict["timeoutSeconds"], !(rawTimeoutObj is NSNull) {
                guard let parsed = numericDouble(from: rawTimeoutObj), parsed.isFinite, parsed > 0 else {
                    throw ActionFlowProposalError.invalidStep(
                        index: index,
                        reason: "wait_for_app_frontmost timeoutSeconds must be a positive number"
                    )
                }
                timeout = ActionFlowStep.clampTimeout(parsed)
            } else {
                timeout = ActionFlowStep.defaultTimeoutSeconds
            }

            return ActionFlowStep(
                id: stepID,
                kind: .waitForAppFrontmost(
                    bundleIdentifier: bundleID,
                    appName: cleanName,
                    timeoutSeconds: timeout
                ),
                isEnabled: isEnabled
            )

        case "delay":
            guard let rawSecondsObj = kindDict["seconds"],
                  let parsedSeconds = numericDouble(from: rawSecondsObj),
                  parsedSeconds.isFinite,
                  parsedSeconds > 0 else {
                throw ActionFlowProposalError.invalidStep(
                    index: index,
                    reason: "delay requires a positive numeric \"seconds\" field"
                )
            }
            let clamped = max(ActionFlowStep.minDelaySeconds, ActionFlowStep.clampDelay(parsedSeconds))
            return ActionFlowStep(
                id: stepID,
                kind: .delay(seconds: clamped),
                isEnabled: isEnabled
            )

        case "system_action":
            guard let rawAction = (kindDict["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawAction.isEmpty else {
                throw ActionFlowProposalError.invalidStep(
                    index: index,
                    reason: "system_action requires an \"action\" field"
                )
            }
            guard let action = SystemQuickAction(rawValue: rawAction) else {
                throw ActionFlowProposalError.unknownStepType("system_action:\(rawAction)")
            }
            let rawTargetBid = (kindDict["targetBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawTargetName = (kindDict["targetAppName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ActionFlowStep(
                id: stepID,
                kind: .systemAction(
                    action: action,
                    targetBundleIdentifier: (rawTargetBid?.isEmpty == false) ? rawTargetBid : nil,
                    targetAppName: (rawTargetName?.isEmpty == false) ? rawTargetName : nil
                ),
                isEnabled: isEnabled
            )

        case "open_website":
            guard let rawURL = (kindDict["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  ActionFlowStep.isValidWebsiteURL(rawURL) else {
                throw ActionFlowProposalError.invalidStep(
                    index: index,
                    reason: "open_website requires a valid URL"
                )
            }
            let normalizedURL = ActionFlowStep.normalizedWebsiteURL(rawURL)
            let rawTitle = (kindDict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let switchTab = (kindDict["switchExistingTab"] as? Bool) ?? true
            return ActionFlowStep(
                id: stepID,
                kind: .openWebsite(
                    url: normalizedURL,
                    title: (rawTitle?.isEmpty == false) ? rawTitle : nil,
                    switchExistingTab: switchTab
                ),
                isEnabled: isEnabled
            )

        case "run_shortcut":
            guard let shortcutName = (kindDict["shortcutName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !shortcutName.isEmpty else {
                throw ActionFlowProposalError.invalidStep(
                    index: index,
                    reason: "run_shortcut requires a non-empty shortcutName"
                )
            }
            return ActionFlowStep(
                id: stepID,
                kind: .runShortcut(shortcutName: shortcutName),
                isEnabled: isEnabled
            )

        case "insert_snippet":
            let rawID = (kindDict["snippetID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawTitle = (kindDict["titleSnapshot"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTitle = (rawTitle?.isEmpty == false) ? rawTitle : nil

            let resolvedUUID: UUID? = {
                if let parsed = UUID(uuidString: rawID) {
                    return parsed
                }
                if let cleanTitle,
                   let matched = context.snippets.first(where: {
                       $0.title.caseInsensitiveCompare(cleanTitle) == .orderedSame
                   }) {
                    return matched.id
                }
                return nil
            }()

            guard let snippetID = resolvedUUID else {
                throw ActionFlowProposalError.invalidStep(
                    index: index,
                    reason: "insert_snippet requires a valid snippetID UUID"
                )
            }

            return ActionFlowStep(
                id: stepID,
                kind: .insertSnippet(snippetID: snippetID, titleSnapshot: cleanTitle),
                isEnabled: isEnabled
            )

        default:
            throw ActionFlowProposalError.unknownStepType(rawType)
        }
    }

    private static func numericDouble(from value: Any) -> Double? {
        if let d = value as? Double {
            return d
        }
        if let i = value as? Int {
            return Double(i)
        }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return nil
            }
            return n.doubleValue
        }
        return nil
    }

    private static func isValidHexColor(_ raw: String) -> Bool {
        guard raw.count == 7, raw.hasPrefix("#") else { return false }
        return raw.dropFirst().allSatisfy(\.isHexDigit)
    }

    private static func stripOptionalMarkdownCodeFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else {
            return trimmed
        }
        var lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return trimmed }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Mac-Local XAI_API_KEY Resolver (Environment or Git-Ignored Local File)

public enum XAIAPIKeyResolver {
    public static let environmentVariableName = "XAI_API_KEY"

    public static func defaultCandidateFileURLs() -> [URL] {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let appSupportBase = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let chocliftSupport = appSupportBase.appendingPathComponent("Choclift", isDirectory: true)

        return [
            cwd.appendingPathComponent(".xai_api_key"),
            cwd.appendingPathComponent(".env.local"),
            cwd.appendingPathComponent(".env"),
            chocliftSupport.appendingPathComponent("xai_api_key"),
            chocliftSupport.appendingPathComponent(".env")
        ]
    }

    public static func resolveKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidateFileURLs: [URL]? = nil
    ) -> String? {
        if let envRaw = environment[environmentVariableName],
           let cleaned = cleanKeyValue(envRaw) {
            return cleaned
        }

        let urls = candidateFileURLs ?? defaultCandidateFileURLs()
        for url in urls {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            let fileName = url.lastPathComponent.lowercased()
            let allowBareSingleLine = (fileName == ".xai_api_key" || fileName == "xai_api_key")
            if let parsed = parseKeyFromFileContents(contents, allowBareSingleLine: allowBareSingleLine) {
                return parsed
            }
        }
        return nil
    }

    public static func redact(_ text: String, key: String?) -> String {
        guard let key, !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: "[REDACTED]")
    }

    private static func parseKeyFromFileContents(_ contents: String, allowBareSingleLine: Bool) -> String? {
        let lines = contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        for line in lines {
            var working = line
            if working.hasPrefix("export ") {
                working = String(working.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            if let eqIndex = working.firstIndex(of: "=") {
                let name = working[..<eqIndex].trimmingCharacters(in: .whitespaces)
                if name == environmentVariableName {
                    let rawVal = String(working[working.index(after: eqIndex)...])
                    if let cleaned = cleanKeyValue(rawVal) {
                        return cleaned
                    }
                }
            }
        }

        if allowBareSingleLine, lines.count == 1, !lines[0].contains("=") {
            return cleanKeyValue(lines[0])
        }
        return nil
    }

    private static func cleanKeyValue(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'") && trimmed.count >= 2) {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - xAI Responses API Client (POST https://api.x.ai/v1/responses, model grok-4.7)

public typealias XAIHTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public struct XAIFlowProposalClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.x.ai/v1")!
    public static let responsesPathComponent = "responses"
    public static let defaultModel = "grok-4.7"

    public let baseURL: URL
    public let model: String
    private let transport: XAIHTTPTransport

    public init(
        baseURL: URL = Self.defaultBaseURL,
        model: String = Self.defaultModel,
        transport: @escaping XAIHTTPTransport = Self.defaultURLSessionTransport
    ) {
        self.baseURL = baseURL
        self.model = model
        self.transport = transport
    }

    public var responsesEndpointURL: URL {
        baseURL.appendingPathComponent(Self.responsesPathComponent)
    }

    public static let defaultURLSessionTransport: XAIHTTPTransport = { request in
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        config.urlCache = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    public func proposeDraft(
        sentence: String,
        apiKey: String,
        originDeviceName: String = "Mac Studio",
        context: ActionFlowProposalCatalogContext = .init()
    ) async throws -> ActionFlowDraft {
        let systemPrompt = ActionFlowSystemPromptBuilder.makeSystemPrompt(context: context)
        let payload = XAIResponsesRequestBody(
            model: model,
            store: false,
            reasoning: .init(effort: "low"),
            text: .init(format: .init(type: "json_object")),
            input: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: sentence)
            ]
        )

        var request = URLRequest(url: responsesEndpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await transport(request)
        } catch let proposalErr as ActionFlowProposalError {
            throw proposalErr
        } catch {
            let safeDesc = XAIAPIKeyResolver.redact(error.localizedDescription, key: apiKey)
            throw ActionFlowProposalError.transportError(safeDesc)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = Self.extractSanitizedHTTPErrorDetail(from: data, apiKey: apiKey)
            throw ActionFlowProposalError.httpStatus(statusCode: httpResponse.statusCode, detail: detail)
        }

        let outputText = try Self.extractAssistantOutputText(from: data, apiKey: apiKey)
        do {
            return try ActionFlowDraftDecoder.decodeDraft(
                from: outputText,
                sourceSentence: sentence,
                originDeviceName: originDeviceName,
                context: context
            )
        } catch let proposalErr as ActionFlowProposalError {
            throw Self.redactProposalError(proposalErr, apiKey: apiKey)
        } catch {
            let safeDesc = XAIAPIKeyResolver.redact(error.localizedDescription, key: apiKey)
            throw ActionFlowProposalError.draftDecodeFailed(safeDesc)
        }
    }

    static func extractAssistantOutputText(from responseData: Data, apiKey: String?) throws -> String {
        let envelope: XAIResponsesEnvelope
        do {
            envelope = try JSONDecoder().decode(XAIResponsesEnvelope.self, from: responseData)
        } catch {
            let safe = XAIAPIKeyResolver.redact(error.localizedDescription, key: apiKey)
            throw ActionFlowProposalError.responseDecodeFailed(safe)
        }

        if let err = envelope.error {
            let msg = err.message ?? err.code ?? "Model error"
            throw ActionFlowProposalError.responseDecodeFailed(XAIAPIKeyResolver.redact(msg, key: apiKey))
        }

        guard let outputItems = envelope.output, !outputItems.isEmpty else {
            throw ActionFlowProposalError.responseDecodeFailed("Response contained an empty output array")
        }

        var collectedTexts: [String] = []
        for item in outputItems {
            guard let parts = item.content else { continue }
            for part in parts {
                if part.type == "refusal", let refusal = part.refusal, !refusal.isEmpty {
                    throw ActionFlowProposalError.responseDecodeFailed(
                        XAIAPIKeyResolver.redact(refusal, key: apiKey)
                    )
                }
                if (part.type == "output_text" || part.type == nil),
                   let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    collectedTexts.append(text)
                }
            }
        }

        let joined = collectedTexts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            throw ActionFlowProposalError.responseDecodeFailed("Response contained no assistant output_text")
        }
        return joined
    }

    private static func extractSanitizedHTTPErrorDetail(from data: Data, apiKey: String?) -> String? {
        guard !data.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errDict = json["error"] as? [String: Any],
               let msg = errDict["message"] as? String {
                let clean = XAIAPIKeyResolver.redact(msg.trimmingCharacters(in: .whitespacesAndNewlines), key: apiKey)
                return clean.isEmpty ? nil : String(clean.prefix(240))
            }
            if let errStr = json["error"] as? String {
                let clean = XAIAPIKeyResolver.redact(errStr.trimmingCharacters(in: .whitespacesAndNewlines), key: apiKey)
                return clean.isEmpty ? nil : String(clean.prefix(240))
            }
            if let msg = json["message"] as? String {
                let clean = XAIAPIKeyResolver.redact(msg.trimmingCharacters(in: .whitespacesAndNewlines), key: apiKey)
                return clean.isEmpty ? nil : String(clean.prefix(240))
            }
        }
        if let rawText = String(data: data, encoding: .utf8) {
            let singleLine = rawText
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = XAIAPIKeyResolver.redact(singleLine, key: apiKey)
            return clean.isEmpty ? nil : String(clean.prefix(200))
        }
        return nil
    }

    private static func redactProposalError(_ error: ActionFlowProposalError, apiKey: String?) -> ActionFlowProposalError {
        switch error {
        case .httpStatus(let code, let detail):
            return .httpStatus(statusCode: code, detail: detail.map { XAIAPIKeyResolver.redact($0, key: apiKey) })
        case .transportError(let detail):
            return .transportError(XAIAPIKeyResolver.redact(detail, key: apiKey))
        case .responseDecodeFailed(let detail):
            return .responseDecodeFailed(XAIAPIKeyResolver.redact(detail, key: apiKey))
        case .draftDecodeFailed(let detail):
            return .draftDecodeFailed(XAIAPIKeyResolver.redact(detail, key: apiKey))
        case .unknownStepType(let rawType):
            return .unknownStepType(XAIAPIKeyResolver.redact(rawType, key: apiKey))
        case .invalidStep(let index, let reason):
            return .invalidStep(index: index, reason: XAIAPIKeyResolver.redact(reason, key: apiKey))
        case .emptySentence, .missingAPIKey, .emptySteps:
            return error
        }
    }
}

private struct XAIResponsesRequestBody: Encodable {
    struct Reasoning: Encodable {
        let effort: String
    }

    struct TextConfig: Encodable {
        struct Format: Encodable {
            let type: String
        }
        let format: Format
    }

    struct InputMessage: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let store: Bool
    let reasoning: Reasoning
    let text: TextConfig
    let input: [InputMessage]
}

private struct XAIResponsesEnvelope: Decodable {
    struct EnvelopeError: Decodable {
        let message: String?
        let code: String?
    }

    struct OutputItem: Decodable {
        struct ContentPart: Decodable {
            let type: String?
            let text: String?
            let refusal: String?
        }

        let type: String?
        let role: String?
        let content: [ContentPart]?
    }

    let id: String?
    let status: String?
    let error: EnvelopeError?
    let output: [OutputItem]?
}

// MARK: - Mac Sentence-to-Flow State Machine (Separate Propose, Confirm, and Cancel)

@MainActor
public final class MacSentenceFlowController: ObservableObject {
    @Published public var sentenceText: String = ""
    @Published public private(set) var isProposing: Bool = false
    @Published public private(set) var pendingDraft: ActionFlowDraft?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var lastError: ActionFlowProposalError?

    private let apiKeyProvider: () -> String?
    private let client: XAIFlowProposalClient
    private let contextProvider: () -> ActionFlowProposalCatalogContext
    private let onSaveFlow: (ActionFlow) -> Void
    private let onExecuteFlow: (ActionFlow, String) async -> ActionFlowRunResult

    private var activeProposalGeneration: UInt64 = 0

    public init(
        apiKeyProvider: @escaping () -> String? = { XAIAPIKeyResolver.resolveKey() },
        client: XAIFlowProposalClient = XAIFlowProposalClient(),
        contextProvider: @escaping () -> ActionFlowProposalCatalogContext = { .init() },
        onSaveFlow: @escaping (ActionFlow) -> Void,
        onExecuteFlow: @escaping (ActionFlow, String) async -> ActionFlowRunResult
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.client = client
        self.contextProvider = contextProvider
        self.onSaveFlow = onSaveFlow
        self.onExecuteFlow = onExecuteFlow
    }

    public var isAPIKeyConfigured: Bool {
        guard let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !key.isEmpty
    }

    /// Asks xAI to propose an `ActionFlowDraft` from `sentence` (or `sentenceText` when `nil`).
    /// Never saves a flow and never calls the executor; confirmation is strictly a separate Mac action.
    @discardableResult
    public func propose(
        sentence: String? = nil,
        originDeviceName: String = "Mac Studio"
    ) async -> Result<ActionFlowDraft, ActionFlowProposalError> {
        let context = contextProvider()
        let rawInput = sentence ?? sentenceText
        let trimmed = String(
            rawInput
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(CompanionClientEngine.maxProposedFlowSentenceCharacters)
        )
        if sentence != nil {
            sentenceText = trimmed
        }

        activeProposalGeneration &+= 1
        let generation = activeProposalGeneration

        pendingDraft = nil
        errorMessage = nil
        lastError = nil

        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            let err = ActionFlowProposalError.missingAPIKey
            lastError = err
            errorMessage = err.localizedDescription(in: context.language)
            isProposing = false
            return .failure(err)
        }

        guard !trimmed.isEmpty else {
            let err = ActionFlowProposalError.emptySentence
            lastError = err
            errorMessage = err.localizedDescription(in: context.language)
            isProposing = false
            return .failure(err)
        }

        isProposing = true
        defer {
            if activeProposalGeneration == generation {
                isProposing = false
            }
        }

        do {
            let draft = try await client.proposeDraft(
                sentence: trimmed,
                apiKey: apiKey,
                originDeviceName: originDeviceName,
                context: context
            )
            guard activeProposalGeneration == generation, !Task.isCancelled else {
                return .failure(.transportError("Cancelled"))
            }
            pendingDraft = draft
            lastError = nil
            errorMessage = nil
            return .success(draft)
        } catch let proposalErr as ActionFlowProposalError {
            guard activeProposalGeneration == generation, !Task.isCancelled else {
                return .failure(proposalErr)
            }
            pendingDraft = nil
            lastError = proposalErr
            errorMessage = XAIAPIKeyResolver.redact(
                proposalErr.localizedDescription(in: context.language),
                key: apiKey
            )
            return .failure(proposalErr)
        } catch {
            let wrapped = ActionFlowProposalError.transportError(
                XAIAPIKeyResolver.redact(error.localizedDescription, key: apiKey)
            )
            guard activeProposalGeneration == generation, !Task.isCancelled else {
                return .failure(wrapped)
            }
            pendingDraft = nil
            lastError = wrapped
            errorMessage = wrapped.localizedDescription(in: context.language)
            return .failure(wrapped)
        }
    }

    /// Separate Mac-only confirmation step: saves the pending draft into the workspace profile
    /// and runs it through the existing flow executor.
    @discardableResult
    public func confirmDraft(expectedDraftID: UUID? = nil) async -> ActionFlowRunResult? {
        guard let draft = pendingDraft else { return nil }
        if let expectedDraftID, draft.id != expectedDraftID {
            return nil
        }
        pendingDraft = nil
        errorMessage = nil
        lastError = nil
        sentenceText = ""

        var flowToSave = draft.flow
        flowToSave.updatedAt = Date()
        onSaveFlow(flowToSave)
        return await onExecuteFlow(flowToSave, "Mac Studio")
    }

    /// Discards any pending draft (or in-flight proposal) without saving or running anything.
    public func cancelDraft() {
        activeProposalGeneration &+= 1
        isProposing = false
        pendingDraft = nil
        errorMessage = nil
        lastError = nil
    }

    public func clearError() {
        errorMessage = nil
        lastError = nil
    }

    /// Builds a sanitized companion feedback message that never leaks the API key, raw model output,
    /// or draft UUID to the phone.
    public static func sanitizedCompanionFeedback(
        for outcome: Result<ActionFlowDraft, ActionFlowProposalError>,
        language: AppLanguage
    ) -> ServerMessage {
        switch outcome {
        case .success:
            return .actionFeedback(
                success: true,
                title: L10n.tr("草稿已在 Mac 就绪", "Draft Ready on Mac", language: language),
                detail: L10n.tr(
                    "请在 Mac 的动作流工作台中核对步骤并点击「确认」后执行。",
                    "Review the steps and tap Confirm on your Mac to save and run.",
                    language: language
                )
            )

        case .failure(let error):
            let detail: String
            switch error {
            case .emptySentence:
                detail = L10n.tr("发送的语句为空", "Sentence cannot be empty", language: language)
            case .missingAPIKey:
                detail = L10n.tr(
                    "Mac 未配置 XAI_API_KEY，未创建动作流",
                    "XAI_API_KEY is missing on your Mac — no flow was created",
                    language: language
                )
            case .httpStatus(let statusCode, _):
                detail = L10n.tr(
                    "Mac 请求模型失败（HTTP \(statusCode)）",
                    "Model request failed on Mac (HTTP \(statusCode))",
                    language: language
                )
            case .transportError:
                detail = L10n.tr(
                    "Mac 连接模型网络失败，请查看 Mac 窗口",
                    "Network error on Mac — check Mac Flows Studio",
                    language: language
                )
            case .responseDecodeFailed, .draftDecodeFailed, .unknownStepType, .invalidStep, .emptySteps:
                detail = L10n.tr(
                    "无法生成可执行的动作流草稿，请查看 Mac 窗口了解详情",
                    "Could not create a valid flow draft — check Mac Flows Studio for details",
                    language: language
                )
            }
            return .actionFeedback(
                success: false,
                title: L10n.tr("动作流建议", "Flow Proposal", language: language),
                detail: detail
            )
        }
    }
}
#endif
