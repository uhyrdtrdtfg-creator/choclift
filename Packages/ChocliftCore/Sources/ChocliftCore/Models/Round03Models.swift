import Foundation

// MARK: - 1. Local Soundboard Models, Cap/Duration Validation & Name Search (Round 3)

/// Metadata for a short audio clip that already lives locally on the Mac.
/// Audio bytes are NEVER uploaded or streamed from companion devices; playback happens on Mac speakers.
public struct SoundboardClip: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let maxBoardCount: Int = 24
    public static let maxDurationSeconds: Double = 8.0
    public static let maxNameLength: Int = 48
    public static let defaultVolume: Double = 0.8

    public static let supportedFileExtensions: Set<String> = [
        "aif", "aiff", "wav", "mp3", "m4a", "caf", "aac", "flac", "mp4"
    ]

    public var id: UUID
    public var name: String
    /// Local filesystem path on the Mac where the audio file resides.
    public var filePath: String
    public var durationSeconds: Double
    public var emoji: String
    public var backgroundHex: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        filePath: String,
        durationSeconds: Double,
        emoji: String = "🔊",
        backgroundHex: String = "#ECFAEE",
        createdAt: Date = Date()
    ) {
        self.id = id
        let fallbackName = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        self.name = Self.sanitizeName(name, fallback: fallbackName)
        self.filePath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.durationSeconds = durationSeconds
        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        self.emoji = trimmedEmoji.isEmpty ? "🔊" : String(trimmedEmoji.prefix(2))
        self.backgroundHex = backgroundHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "#ECFAEE"
            : backgroundHex
        self.createdAt = createdAt
    }

    public static func sanitizeName(_ raw: String, fallback: String = "Sound") -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !collapsed.isEmpty {
            return String(collapsed.prefix(maxNameLength))
        }
        let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackTrimmed.isEmpty ? "Sound" : String(fallbackTrimmed.prefix(maxNameLength))
    }

    public var formattedDuration: String {
        let clamped = max(0.1, min(Self.maxDurationSeconds, durationSeconds))
        return String(format: "%.1fs", clamped)
    }

    public var isDurationAllowed: Bool {
        durationSeconds.isFinite && durationSeconds > 0 && durationSeconds <= Self.maxDurationSeconds
    }
}

public enum SoundboardValidationError: Error, Equatable, Sendable {
    case boardFull(limit: Int)
    case missingFile
    case unsupportedFormat
    case duplicateFile
    case invalidDuration
    case durationTooLong(seconds: Double, maxSeconds: Double)

    public func localizedDescription(in language: AppLanguage = .system) -> String {
        switch self {
        case .boardFull(let limit):
            return L10n.tr(
                "音效板最多容纳 \(limit) 个音效，请先移除旧音效。",
                "Soundboard is capped at \(limit) sounds. Remove one before adding more.",
                language: language
            )
        case .missingFile:
            return L10n.tr(
                "未找到该本地音频文件。",
                "Local audio file could not be found on this Mac.",
                language: language
            )
        case .unsupportedFormat:
            return L10n.tr(
                "不支持该音频格式（支持 WAV、MP3、M4A、AIFF、CAF、AAC、FLAC）。",
                "Unsupported audio format (use WAV, MP3, M4A, AIFF, CAF, AAC, or FLAC).",
                language: language
            )
        case .duplicateFile:
            return L10n.tr(
                "该音频文件已在音效板中。",
                "That audio file is already on the soundboard.",
                language: language
            )
        case .invalidDuration:
            return L10n.tr(
                "无法读取有效的音频时长。",
                "Could not read a valid audio duration from that file.",
                language: language
            )
        case .durationTooLong(let seconds, let maxSeconds):
            let actualText = String(format: "%.1fs", seconds)
            let maxText = String(format: "%.0fs", maxSeconds)
            return L10n.tr(
                "音频时长为 \(actualText)，超过 \(maxText) 上限，已拒绝添加。",
                "Audio clip is \(actualText); files over \(maxText) are rejected.",
                language: language
            )
        }
    }
}

public enum SoundboardCatalogValidator {
    public static func isSupportedAudioPath(_ filePath: String) -> Bool {
        let trimmed = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ext = URL(fileURLWithPath: trimmed).pathExtension.lowercased()
        return SoundboardClip.supportedFileExtensions.contains(ext)
    }

    public static func normalizedFileKey(_ filePath: String) -> String {
        let trimmed = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    public static func validateAddition(
        filePath: String,
        durationSeconds: Double,
        existingClips: [SoundboardClip]
    ) -> Result<Void, SoundboardValidationError> {
        guard existingClips.count < SoundboardClip.maxBoardCount else {
            return .failure(.boardFull(limit: SoundboardClip.maxBoardCount))
        }
        let trimmedPath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return .failure(.missingFile)
        }
        guard isSupportedAudioPath(trimmedPath) else {
            return .failure(.unsupportedFormat)
        }
        let candidateKey = normalizedFileKey(trimmedPath)
        let isDuplicate = existingClips.contains {
            normalizedFileKey($0.filePath) == candidateKey
        }
        if isDuplicate {
            return .failure(.duplicateFile)
        }
        guard durationSeconds.isFinite && durationSeconds > 0 else {
            return .failure(.invalidDuration)
        }
        guard durationSeconds <= SoundboardClip.maxDurationSeconds else {
            return .failure(.durationTooLong(
                seconds: durationSeconds,
                maxSeconds: SoundboardClip.maxDurationSeconds
            ))
        }
        return .success(())
    }

    /// Sanitizes decoded or incoming soundboard arrays to enforce the <= 24 cap and <= 8s duration rule.
    public static func sanitizeBoard(_ clips: [SoundboardClip]) -> [SoundboardClip] {
        var result: [SoundboardClip] = []
        var seenIDs = Set<UUID>()
        var seenPaths = Set<String>()

        for clip in clips {
            guard result.count < SoundboardClip.maxBoardCount else { break }
            guard !seenIDs.contains(clip.id) else { continue }
            let pathKey = normalizedFileKey(clip.filePath)
            guard !pathKey.isEmpty,
                  isSupportedAudioPath(clip.filePath),
                  !seenPaths.contains(pathKey),
                  clip.isDurationAllowed else {
                continue
            }
            seenIDs.insert(clip.id)
            seenPaths.insert(pathKey)
            result.append(clip)
        }
        return result
    }
}

/// Pure, deterministic sound-name search used by iPhone, iPad, and Mac Studio.
public enum SoundboardSearch {
    public static func filter(_ clips: [SoundboardClip], query: String) -> [SoundboardClip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clips }

        let tokens = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .map { Self.fold($0) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return clips }

        return clips.filter { clip in
            let foldedName = Self.fold(clip.name)
            return tokens.allSatisfy { token in
                foldedName.contains(token)
            }
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

// MARK: - 2. Slot Reference Coordinates & Resolution (Round 3)

public struct SlotCoordinate: Codable, Equatable, Hashable, Sendable {
    public var pageID: UUID
    public var slotIndex: Int

    public init(pageID: UUID, slotIndex: Int) {
        self.pageID = pageID
        self.slotIndex = slotIndex
    }
}

public enum SlotReferenceResolution: Equatable, Sendable {
    case resolved(
        pageID: UUID,
        pageIndex: Int,
        pageTitle: String,
        pageEmoji: String,
        slotIndex: Int,
        item: BarItem
    )
    case missing

    public var resolvedItem: BarItem? {
        if case .resolved(_, _, _, _, _, let item) = self {
            return item
        }
        return nil
    }

    public var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}

// MARK: - 3. Companion Search Across Page Tiles, Snippets, and Flows (Round 3)

public enum CompanionSearchScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case tiles
    case snippets
    case flows

    public var id: String { rawValue }

    public func title(in language: AppLanguage = .system) -> String {
        switch self {
        case .all: return L10n.tr("全部", "All", language: language)
        case .tiles: return L10n.tr("按键格", "Tiles", language: language)
        case .snippets: return L10n.tr("片段", "Snippets", language: language)
        case .flows: return L10n.tr("动作流", "Flows", language: language)
        }
    }

    public var sfSymbol: String {
        switch self {
        case .all: return "magnifyingglass"
        case .tiles: return "square.grid.2x2.fill"
        case .snippets: return "text.quote"
        case .flows: return "bolt.horizontal.circle.fill"
        }
    }
}

public enum CompanionSearchResultPayload: Equatable, Hashable, Sendable {
    case tile(
        pageID: UUID,
        pageIndex: Int,
        pageTitle: String,
        pageEmoji: String,
        slotIndex: Int,
        item: BarItem,
        effectiveItem: BarItem,
        isReference: Bool
    )
    case snippet(TextSnippet)
    case flow(ActionFlow)
}

public struct CompanionSearchResult: Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var badgeText: String?
    public var payload: CompanionSearchResultPayload

    public init(
        id: String,
        title: String,
        subtitle: String,
        badgeText: String? = nil,
        payload: CompanionSearchResultPayload
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.badgeText = badgeText
        self.payload = payload
    }
}

/// Pure search engine across page tiles, text snippets, and action flows.
/// Filtering is side-effect-free so typing never auto-runs any action.
public enum CompanionWorkspaceSearch {
    public static func search(
        in profile: ChocliftWorkspaceProfile,
        query: String,
        scope: CompanionSearchScope = .all,
        language: AppLanguage = .system
    ) -> [CompanionSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .map { SoundboardSearch.fold($0) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        var results: [CompanionSearchResult] = []

        if scope == .all || scope == .tiles {
            for (pageIdx, page) in profile.pages.enumerated() {
                for (slotIdx, maybeItem) in page.slots.enumerated() {
                    guard let item = maybeItem else { continue }
                    let origin = SlotCoordinate(pageID: page.id, slotIndex: slotIdx)

                    let effectiveItem: BarItem
                    let isRef: Bool
                    switch item.kind {
                    case .folder(let folder):
                        let folderLabel = "\(page.iconEmoji) \(page.title) · \(folder.emoji) \(folder.displayTitle(in: language))"
                        for (childIdx, child) in folder.children.enumerated() {
                            let childTitle = profile.displayTitle(for: child, from: origin, in: language)
                            var childFields = tileSearchableStrings(
                                effectiveItem: child,
                                page: page,
                                profile: profile,
                                language: language
                            )
                            childFields.append(folder.displayTitle(in: language))
                            childFields.append(folder.title)
                            let childHaystack = SoundboardSearch.fold(childFields.joined(separator: " "))
                            guard tokens.allSatisfy({ childHaystack.contains($0) }) else { continue }
                            let childShortcutBadge: String? = {
                                if case .systemAction(let action, _, _) = child.kind {
                                    return action.sentKeyboardShortcut
                                }
                                return nil
                            }()
                            results.append(
                                CompanionSearchResult(
                                    id: "folder-child-\(page.id.uuidString)-\(slotIdx)-\(childIdx)-\(child.id.uuidString)",
                                    title: childTitle,
                                    subtitle: folderLabel,
                                    badgeText: childShortcutBadge,
                                    payload: .tile(
                                        pageID: page.id,
                                        pageIndex: pageIdx,
                                        pageTitle: page.title,
                                        pageEmoji: page.iconEmoji,
                                        slotIndex: slotIdx,
                                        item: child,
                                        effectiveItem: child,
                                        isReference: false
                                    )
                                )
                            )
                        }
                        continue
                    case .slotReference:
                        guard case .resolved(_, _, _, _, _, let target) = profile.resolveBarItem(item, from: origin) else {
                            // Missing reference slots do not run anything and are excluded from runnable search hits.
                            continue
                        }
                        effectiveItem = target
                        isRef = true
                    default:
                        effectiveItem = item
                        isRef = false
                    }

                    let displayTitle = profile.displayTitle(for: item, from: origin, in: language)
                    let searchableFields = tileSearchableStrings(
                        effectiveItem: effectiveItem,
                        page: page,
                        profile: profile,
                        language: language
                    )
                    let haystack = SoundboardSearch.fold(searchableFields.joined(separator: " "))
                    guard tokens.allSatisfy({ haystack.contains($0) }) else { continue }

                    let pageLabel = "\(page.iconEmoji) \(page.title) · #\(slotIdx + 1)"
                    let subtitle: String = {
                        if isRef {
                            return L10n.tr("\(pageLabel)（引用）", "\(pageLabel) (Reference)", language: language)
                        }
                        return pageLabel
                    }()
                    let shortcutBadge: String? = {
                        if case .systemAction(let action, _, _) = effectiveItem.kind {
                            return action.sentKeyboardShortcut
                        }
                        return nil
                    }()

                    results.append(
                        CompanionSearchResult(
                            id: "tile-\(page.id.uuidString)-\(slotIdx)",
                            title: displayTitle,
                            subtitle: subtitle,
                            badgeText: shortcutBadge,
                            payload: .tile(
                                pageID: page.id,
                                pageIndex: pageIdx,
                                pageTitle: page.title,
                                pageEmoji: page.iconEmoji,
                                slotIndex: slotIdx,
                                item: item,
                                effectiveItem: effectiveItem,
                                isReference: isRef
                            )
                        )
                    )
                }
            }
        }

        if scope == .all || scope == .snippets {
            for snippet in profile.snippets {
                let title = snippet.displayTitle(in: language)
                let haystack = SoundboardSearch.fold("\(snippet.title) \(title) \(snippet.body)")
                guard tokens.allSatisfy({ haystack.contains($0) }) else { continue }

                results.append(
                    CompanionSearchResult(
                        id: "snippet-\(snippet.id.uuidString)",
                        title: title,
                        subtitle: snippet.singleLinePreview,
                        badgeText: L10n.tr("片段", "Snippet", language: language),
                        payload: .snippet(snippet)
                    )
                )
            }
        }

        if scope == .all || scope == .flows {
            for flow in profile.flows {
                let stepText = flow.steps
                    .map { $0.displayTitle(in: .english) + " " + $0.displayTitle(in: .chinese) }
                    .joined(separator: " ")
                let haystack = SoundboardSearch.fold("\(flow.name) \(flow.emoji) \(stepText)")
                guard tokens.allSatisfy({ haystack.contains($0) }) else { continue }

                let stepLabel = L10n.tr("\(flow.enabledStepCount) 步动作流", "\(flow.enabledStepCount)-step Flow", language: language)
                results.append(
                    CompanionSearchResult(
                        id: "flow-\(flow.id.uuidString)",
                        title: flow.name,
                        subtitle: stepLabel,
                        badgeText: L10n.tr("动作流", "Flow", language: language),
                        payload: .flow(flow)
                    )
                )
            }
        }

        return results
    }

    private static func tileSearchableStrings(
        effectiveItem: BarItem,
        page: BarPage,
        profile: ChocliftWorkspaceProfile,
        language: AppLanguage
    ) -> [String] {
        var parts: [String] = [
            effectiveItem.displayTitle(in: language),
            effectiveItem.displayTitle(in: .english),
            effectiveItem.displayTitle(in: .chinese),
            page.title
        ]
        switch effectiveItem.kind {
        case .macApp(let bundleID, let appName, _, _):
            parts.append(bundleID)
            parts.append(appName)
        case .shortcut(let shortcutName, let emoji, _):
            parts.append(shortcutName)
            parts.append(emoji)
        case .website(let url, let title, let emoji, _, _):
            parts.append(url)
            parts.append(title)
            parts.append(emoji)
        case .systemAction(let action, let customTitle, _):
            parts.append(action.title(in: .english))
            parts.append(action.title(in: .chinese))
            parts.append(action.compactTitle(in: .english))
            parts.append(action.compactTitle(in: .chinese))
            if let customTitle { parts.append(customTitle) }
            if let shortcut = action.sentKeyboardShortcut { parts.append(shortcut) }
        case .flow(let flowID, let snapshot, let emoji, _, _):
            parts.append(snapshot)
            parts.append(emoji)
            if let flow = profile.flow(withID: flowID) {
                parts.append(flow.name)
            }
        case .soundboard(let soundID, let snapshot, let emoji, _):
            parts.append(snapshot)
            parts.append(emoji)
            if let clip = profile.soundboardClip(withID: soundID) {
                parts.append(clip.name)
            }
        case .slotReference:
            break
        case .folder(let folder):
            parts.append(folder.title)
            parts.append(folder.emoji)
        }
        return parts
    }
}
