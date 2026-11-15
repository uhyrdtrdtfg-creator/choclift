import Foundation

public enum PhoneClipboardPaste {
    public static let maxCharacters = 2000

    public static func clamp(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if trimmed.count > maxCharacters {
            return String(trimmed.prefix(maxCharacters))
        }
        return trimmed
    }
}
