import Foundation

// MARK: - 1. Pinned Clipboard Items (Max 8 Items, <= 280 Plain-Text Chars, Synced in Workspace Profile)

/// A plain-text item pinned from the Mac clipboard preview and persisted in `ChocliftWorkspaceProfile`.
/// Never stores images, file URLs, password/concealed items, or more than 280 `Character`s.
public struct PinnedClipboardItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let maxPinnedCount: Int = 8
    public static let maxCharacterLimit: Int = ClipboardPreviewSnapshot.maxPreviewCharacters // 280

    public let id: UUID
    public let text: String
    public let pinnedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case pinnedAt
    }

    public init?(
        id: UUID = UUID(),
        text: String,
        pinnedAt: Date = Date()
    ) {
        guard let safeText = Self.sanitizedText(text) else {
            return nil
        }
        self.id = id
        self.text = safeText
        self.pinnedAt = pinnedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let rawText = try container.decode(String.self, forKey: .text)
        let decodedDate = try container.decodeIfPresent(Date.self, forKey: .pinnedAt) ?? Date()
        guard let safeText = Self.sanitizedText(rawText) else {
            throw DecodingError.dataCorruptedError(
                forKey: .text,
                in: container,
                debugDescription: "PinnedClipboardItem text must be non-empty plain text."
            )
        }
        self.id = decodedID
        self.text = safeText
        self.pinnedAt = decodedDate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        let safeText = Self.sanitizedText(text) ?? String(text.prefix(Self.maxCharacterLimit))
        try container.encode(safeText, forKey: .text)
        try container.encode(pinnedAt, forKey: .pinnedAt)
    }

    /// Single-line compact label for chips and rows.
    public var singleLinePreview: String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? text : collapsed
    }

    /// Rejects empty/whitespace-only strings and clamps plain text strictly to at most 280 `Character`s.
    public static func sanitizedText(_ raw: String?) -> String? {
        guard let raw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if raw.count > maxCharacterLimit {
            return String(raw.prefix(maxCharacterLimit))
        }
        return raw
    }
}

public enum PinnedClipboardShelf {
    public static let maxPinnedCount: Int = PinnedClipboardItem.maxPinnedCount
    public static let maxCharacterLimit: Int = PinnedClipboardItem.maxCharacterLimit

    /// Sanitizes an array of pinned clipboard items:
    /// - Enforces non-empty text and `<= 280` characters per item
    /// - Optionally restricts items to `allowedTexts` (e.g. already-pinned Mac items union observed safe previews)
    /// - Deduplicates by exact `text` while preserving order
    /// - Enforces the 8-item cap (`maxPinnedCount == 8`)
    public static func sanitize(
        _ items: [PinnedClipboardItem],
        allowedTexts: Set<String>? = nil
    ) -> [PinnedClipboardItem] {
        var seenTexts = Set<String>()
        var result: [PinnedClipboardItem] = []
        result.reserveCapacity(min(items.count, maxPinnedCount))

        for candidate in items {
            guard let safeText = PinnedClipboardItem.sanitizedText(candidate.text) else {
                continue
            }
            if let allowedTexts, !allowedTexts.contains(safeText) {
                continue
            }
            guard !seenTexts.contains(safeText) else {
                continue
            }
            guard let normalized = PinnedClipboardItem(
                id: candidate.id,
                text: safeText,
                pinnedAt: candidate.pinnedAt
            ) else {
                continue
            }
            seenTexts.insert(safeText)
            result.append(normalized)
            if result.count >= maxPinnedCount {
                break
            }
        }

        return result
    }

    /// Pins a safe `ClipboardPreviewSnapshot` that appeared in the Mac clipboard preview.
    /// Rejects `.empty` snapshots (which already filtered out images, files, and passwords),
    /// enforces `<= 280` characters, deduplicates, and caps at 8 items.
    public static func pin(
        preview: ClipboardPreviewSnapshot,
        into existing: [PinnedClipboardItem],
        id: UUID = UUID(),
        pinnedAt: Date = Date()
    ) -> (updated: [PinnedClipboardItem], didPin: Bool) {
        let normalized = sanitize(existing)
        guard let rawPreviewText = preview.previewText,
              let safeText = PinnedClipboardItem.sanitizedText(rawPreviewText) else {
            return (normalized, false)
        }
        if normalized.contains(where: { $0.text == safeText }) {
            return (normalized, true)
        }
        guard normalized.count < maxPinnedCount,
              let created = PinnedClipboardItem(id: id, text: safeText, pinnedAt: pinnedAt) else {
            return (normalized, false)
        }
        return (normalized + [created], true)
    }

    /// Evaluates raw Mac pasteboard types + string and pins only safe plain text (`<= 280` chars, max 8 items).
    /// Images, file URLs, and concealed/password pasteboard types are rejected.
    public static func pinFromPasteboard(
        pasteboardTypes: Set<String>,
        string: String?,
        into existing: [PinnedClipboardItem],
        id: UUID = UUID(),
        pinnedAt: Date = Date()
    ) -> (updated: [PinnedClipboardItem], didPin: Bool) {
        let snapshot = ClipboardPreviewEvaluator.evaluate(
            pasteboardTypes: pasteboardTypes,
            string: string
        )
        return pin(preview: snapshot, into: existing, id: id, pinnedAt: pinnedAt)
    }

    /// Pins `text` on a companion ONLY if it already appeared in `observedPreviewTexts`
    /// (the Mac clipboard previews received by the phone). Clamps to 280 characters and caps at 8 items.
    public static func pinObservedPreviewText(
        _ text: String,
        observedPreviewTexts: Set<String>,
        into existing: [PinnedClipboardItem],
        id: UUID = UUID(),
        pinnedAt: Date = Date()
    ) -> (updated: [PinnedClipboardItem], didPin: Bool) {
        let normalized = sanitize(existing)
        guard let safeText = PinnedClipboardItem.sanitizedText(text),
              observedPreviewTexts.contains(safeText) else {
            return (normalized, false)
        }
        if normalized.contains(where: { $0.text == safeText }) {
            return (normalized, true)
        }
        guard normalized.count < maxPinnedCount,
              let created = PinnedClipboardItem(id: id, text: safeText, pinnedAt: pinnedAt) else {
            return (normalized, false)
        }
        return (normalized + [created], true)
    }

    public static func unpin(
        id: UUID,
        from existing: [PinnedClipboardItem]
    ) -> (updated: [PinnedClipboardItem], didUnpin: Bool) {
        let normalized = sanitize(existing)
        let filtered = normalized.filter { $0.id != id }
        return (filtered, filtered.count != normalized.count)
    }

    public static func unpin(
        text: String,
        from existing: [PinnedClipboardItem]
    ) -> (updated: [PinnedClipboardItem], didUnpin: Bool) {
        let normalized = sanitize(existing)
        guard let safeText = PinnedClipboardItem.sanitizedText(text) else {
            return (normalized, false)
        }
        let filtered = normalized.filter { $0.text != safeText }
        return (filtered, filtered.count != normalized.count)
    }
}

// MARK: - 2. Now-Playing Progress Formatting (Read-Only Elapsed / Duration; Missing Duration -> Title Only)

public enum NowPlayingProgressFormatter {
    /// Formats non-negative integer seconds as `m:ss` (under 1 hour) or `h:mm:ss` (1 hour or longer).
    public static func formatTimestamp(_ totalSeconds: Int) -> String {
        let clamped = max(0, totalSeconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let seconds = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Returns `"elapsed / duration"` ONLY when the system provides both finite `elapsedSeconds >= 0`
    /// and finite `durationSeconds > 0`. When duration is missing (`nil`, `<= 0`, `NaN`, or infinite),
    /// returns `nil` so the Now Playing row shows the title only.
    public static func formattedProgress(
        elapsedSeconds: Double?,
        durationSeconds: Double?
    ) -> String? {
        guard let rawDuration = durationSeconds,
              rawDuration.isFinite,
              !rawDuration.isNaN,
              rawDuration > 0,
              let rawElapsed = elapsedSeconds,
              rawElapsed.isFinite,
              !rawElapsed.isNaN else {
            return nil
        }

        let safeDurationSeconds = max(1, Int(rawDuration.rounded(.down)))
        let clampedElapsed = min(max(0.0, rawElapsed), rawDuration)
        let safeElapsedSeconds = min(safeDurationSeconds, max(0, Int(clampedElapsed.rounded(.down))))
        return "\(formatTimestamp(safeElapsedSeconds)) / \(formatTimestamp(safeDurationSeconds))"
    }

    /// Resolves the text components for the Now Playing strip row:
    /// - Returns `nil` when nothing is playing/loaded.
    /// - Returns `(title, nil)` when `durationSeconds` is missing so only the title is shown.
    /// - Returns `(title, "m:ss / m:ss")` when both elapsed and duration are provided.
    public static func rowDisplayContent(
        for status: NowPlayingStatus?
    ) -> (title: String, progressText: String?)? {
        guard let status, let title = status.primaryDisplayText else {
            return nil
        }
        return (title, status.formattedProgressText)
    }
}

// MARK: - 3. Lock Screen Two-Tap Confirmation Controller (3s Window, Separate from Sleep Display)

public enum Round09LockScreenTapOutcome: Equatable, Sendable {
    /// First tap (or tap after 3-second expiry): arms confirmation and MUST NOT lock the Mac.
    case requireSecondTap(expiresAt: TimeInterval)
    /// Second tap within the 3-second confirmation window: disarms and locks the Mac.
    case confirmedExecute
}

/// Dedicated 3-second second-tap confirm controller for the companion Lock Screen button,
/// backed by `DestructiveActionConfirmGate` and completely separate from Sleep Display.
public struct Round09LockScreenConfirmController: Equatable, Sendable {
    public static let targetID = "round09.lock_mac_screen"

    public private(set) var gate: DestructiveActionConfirmGate

    public init(
        confirmationWindowSeconds: TimeInterval = CompanionInteractionPolicy.destructiveConfirmWindowSeconds
    ) {
        self.gate = DestructiveActionConfirmGate(confirmationWindowSeconds: confirmationWindowSeconds)
    }

    public var confirmationWindowSeconds: TimeInterval {
        gate.confirmationWindowSeconds
    }

    public func isArmed(at now: TimeInterval) -> Bool {
        gate.isArmed(targetID: Self.targetID, at: now)
    }

    public mutating func registerTap(at now: TimeInterval) -> Round09LockScreenTapOutcome {
        let decision = gate.registerTap(
            targetID: Self.targetID,
            isDestructive: true,
            at: now
        )
        switch decision {
        case .requireSecondTap(let expiresAt):
            return .requireSecondTap(expiresAt: expiresAt)
        case .confirmedRun, .runImmediately:
            return .confirmedExecute
        }
    }

    public mutating func expireIfNeeded(at now: TimeInterval) {
        gate.expireIfNeeded(at: now)
    }

    public mutating func disarm() {
        gate.disarm()
    }

    public static func title(compact: Bool, in lang: AppLanguage) -> String {
        compact
            ? L10n.tr("锁屏", "Lock", language: lang)
            : L10n.tr("锁定屏幕", "Lock Screen", language: lang)
    }

    public static func armedTitle(compact: Bool, in lang: AppLanguage) -> String {
        compact
            ? L10n.tr("再点确认", "Tap Again", language: lang)
            : L10n.tr("再点确认锁屏", "Tap Again to Lock", language: lang)
    }

    public static func promptMessage(in lang: AppLanguage) -> String {
        let label = title(compact: false, in: lang)
        return L10n.tr(
            "3 秒内再点一次确认：\(label)",
            "Tap again within 3s: \(label)",
            language: lang
        )
    }
}

// MARK: - 4. Hide Other Windows Copy & Window-Undo Capability Policy

public enum HideOtherWindowsPolicy {
    /// `WindowMoveUndoBuffer` only records `WindowQuartzRect` AX window frames (`kAXPositionAttribute` /
    /// `kAXSizeAttribute`) and cannot unhide `NSRunningApplication` instances hidden via `app.hide()`.
    /// Therefore one-level window undo is intentionally left unchanged when hiding other apps.
    public static let canExistingWindowMoveUndoRestoreAppVisibility = false

    public static func buttonTitle(compact: Bool, in lang: AppLanguage) -> String {
        compact
            ? L10n.tr("隐藏其他", "Hide Others", language: lang)
            : L10n.tr("隐藏其他窗口", "Hide Others", language: lang)
    }
}

// MARK: - 5. Read-Only Frontmost Mac App Strip Formatter (Non-Launching)

public enum FrontmostAppStripFormatter {
    public static let maxDisplayCharacters: Int = 44

    public static func sanitizedAppName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if trimmed.count > maxDisplayCharacters {
            return String(trimmed.prefix(maxDisplayCharacters))
        }
        return trimmed
    }

    /// Formats the read-only frontmost Mac app label shown next to the Mac battery badge on the strip.
    public static func displayText(
        appName: String?,
        isConnected: Bool,
        in language: AppLanguage = .system
    ) -> String {
        guard isConnected else {
            return L10n.tr("前台 —", "Frontmost —", language: language)
        }
        if let clean = sanitizedAppName(appName) {
            return clean
        }
        return L10n.tr("桌面", "Desktop", language: language)
    }
}
