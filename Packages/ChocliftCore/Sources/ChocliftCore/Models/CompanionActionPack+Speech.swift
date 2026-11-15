import Foundation

public enum SpeechCompanionAction: String, CaseIterable, Equatable, Hashable, Sendable {
    case speakSelection = "speech.speak_selection"
    case stop = "speech.stop"

    public var companionAction: CompanionAction {
        switch self {
        case .speakSelection:
            return CompanionAction(
                id: rawValue,
                titleZh: "朗读选中文字",
                titleEn: "Speak Selection",
                sfSymbol: "speaker.wave.2"
            )
        case .stop:
            return CompanionAction(
                id: rawValue,
                titleZh: "停止朗读",
                titleEn: "Stop Speaking",
                sfSymbol: "speaker.slash"
            )
        }
    }
}

extension CompanionActionCatalog {
    public static let speechPack: [CompanionAction] = SpeechCompanionAction.allCases.map(\.companionAction)
}

public enum SpeechActionFailure: Error, Equatable, Sendable {
    case unknownAction(String)
    case emptySelection
    case selectionUnavailable(String)
    case synthesizerFailed

    public func message(in language: AppLanguage = .system) -> String {
        switch self {
        case .unknownAction(let id):
            return L10n.tr("不支持的朗读操作：\(id)", "Unsupported speech action: \(id)", language: language)
        case .emptySelection:
            return L10n.tr("当前前台应用没有选中的文字", "No text is selected in the frontmost app", language: language)
        case .selectionUnavailable(let detail):
            return detail
        case .synthesizerFailed:
            return L10n.tr("系统语音合成器无法开始朗读", "System speech synthesizer could not start speaking", language: language)
        }
    }
}

public enum SpeechTextClamp {
    public static let maxCharacters = 500

    public static func clamp(
        _ raw: String?,
        limit: Int = maxCharacters
    ) -> Result<String, SpeechActionFailure> {
        guard limit > 0, let raw else {
            return .failure(.emptySelection)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptySelection)
        }
        if trimmed.count > limit {
            return .success(String(trimmed.prefix(limit)))
        }
        return .success(trimmed)
    }

    public static func clampedText(
        _ raw: String?,
        limit: Int = maxCharacters
    ) -> String? {
        if case .success(let text) = clamp(raw, limit: limit) {
            return text
        }
        return nil
    }
}

public struct SpeechActionOutcome: Equatable, Sendable {
    public let success: Bool
    public let spokenText: String?
    public let message: String

    public init(success: Bool, spokenText: String?, message: String) {
        self.success = success
        self.spokenText = spokenText
        self.message = message
    }
}

public protocol SpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    @discardableResult
    func startSpeaking(_ string: String) -> Bool
    func stopSpeaking()
}

public final class SpeechUtteranceController {
    private let makeSynthesizer: () -> SpeechSynthesizing
    private var synthesizer: SpeechSynthesizing?

    public init(makeSynthesizer: @escaping () -> SpeechSynthesizing) {
        self.makeSynthesizer = makeSynthesizer
    }

    public var isSpeaking: Bool {
        synthesizer?.isSpeaking ?? false
    }

    @discardableResult
    public func speak(_ text: String) -> Bool {
        let active: SpeechSynthesizing
        if let existing = synthesizer {
            existing.stopSpeaking()
            active = existing
        } else {
            let created = makeSynthesizer()
            synthesizer = created
            active = created
        }
        return active.startSpeaking(text)
    }

    public func stop() {
        synthesizer?.stopSpeaking()
    }
}

extension SpeechCompanionAction {
    public static func execute(
        id: String,
        language: AppLanguage = .system,
        readSelectedText: () -> Result<String, SpeechActionFailure>,
        speak: (String) -> Bool,
        stop: () -> Void
    ) -> SpeechActionOutcome {
        guard let action = SpeechCompanionAction(rawValue: id) else {
            return SpeechActionOutcome(
                success: false,
                spokenText: nil,
                message: SpeechActionFailure.unknownAction(id).message(in: language)
            )
        }

        switch action {
        case .stop:
            stop()
            return SpeechActionOutcome(
                success: true,
                spokenText: nil,
                message: L10n.tr("已停止朗读", "Stopped speaking", language: language)
            )

        case .speakSelection:
            switch readSelectedText() {
            case .failure(let failure):
                return SpeechActionOutcome(
                    success: false,
                    spokenText: nil,
                    message: failure.message(in: language)
                )
            case .success(let rawSelection):
                switch SpeechTextClamp.clamp(rawSelection) {
                case .failure(let failure):
                    return SpeechActionOutcome(
                        success: false,
                        spokenText: nil,
                        message: failure.message(in: language)
                    )
                case .success(let clampedText):
                    guard speak(clampedText) else {
                        return SpeechActionOutcome(
                            success: false,
                            spokenText: nil,
                            message: SpeechActionFailure.synthesizerFailed.message(in: language)
                        )
                    }
                    return SpeechActionOutcome(
                        success: true,
                        spokenText: clampedText,
                        message: L10n.tr(
                            "正在朗读选中文字（\(clampedText.count) 字）",
                            "Speaking selection (\(clampedText.count) chars)",
                            language: language
                        )
                    )
                }
            }
        }
    }
}
