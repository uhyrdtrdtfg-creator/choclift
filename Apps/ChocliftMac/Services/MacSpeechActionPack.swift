import AppKit
import ChocliftCore
import Foundation

@MainActor
final class MacSpeechSynthesizerHolder {
    private final class SystemVoiceSynthesizer: SpeechSynthesizing {
        private let synthesizer: NSSpeechSynthesizer

        init() {
            self.synthesizer = NSSpeechSynthesizer(voice: nil) ?? NSSpeechSynthesizer()
        }

        var isSpeaking: Bool {
            synthesizer.isSpeaking
        }

        @discardableResult
        func startSpeaking(_ string: String) -> Bool {
            synthesizer.startSpeaking(string)
        }

        func stopSpeaking() {
            synthesizer.stopSpeaking()
        }
    }

    private let controller = SpeechUtteranceController {
        SystemVoiceSynthesizer()
    }

    @discardableResult
    func speak(_ text: String) -> Bool {
        controller.speak(text)
    }

    func stop() {
        controller.stop()
    }
}

enum MacSpeechActionPack {
    @MainActor
    private static let holder = MacSpeechSynthesizerHolder()

    @MainActor
    private static let windowService = MacAccessibilityAndWindowService()

    static func run(
        id: String,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                runOnMainActor(id: id, language: language)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                runOnMainActor(id: id, language: language)
            }
        }
    }

    @MainActor
    private static func runOnMainActor(
        id: String,
        language: AppLanguage
    ) -> (success: Bool, message: String) {
        let outcome = SpeechCompanionAction.execute(
            id: id,
            language: language,
            readSelectedText: {
                do {
                    let selection = try windowService.readFrontmostSelection()
                    return .success(selection.text)
                } catch OrcaSelectionError.emptySelection {
                    return .failure(.emptySelection)
                } catch OrcaSelectionError.unavailable(let detail) {
                    return .failure(.selectionUnavailable(detail))
                } catch {
                    return .failure(.selectionUnavailable(error.localizedDescription))
                }
            },
            speak: { clampedText in
                holder.speak(clampedText)
            },
            stop: {
                holder.stop()
            }
        )
        return (outcome.success, outcome.message)
    }
}
