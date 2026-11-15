import Foundation

/// Extra companion actions that stay out of `SystemQuickAction`.
/// Each action lives in one worker file. Do not add cases to `SystemQuickAction` for these.
public struct CompanionAction: Equatable, Hashable, Sendable, Identifiable, Codable {
    public var id: String
    public var titleZh: String
    public var titleEn: String
    public var sfSymbol: String

    public init(id: String, titleZh: String, titleEn: String, sfSymbol: String) {
        self.id = id
        self.titleZh = titleZh
        self.titleEn = titleEn
        self.sfSymbol = sfSymbol
    }

    public func title(in lang: AppLanguage = .system) -> String {
        L10n.tr(titleZh, titleEn, language: lang)
    }
}

public enum CompanionActionCatalog {
    /// Stable ids. Workers append only inside `CompanionActionPack+<Group>.swift`.
    public static let all: [CompanionAction] = windowPack + mediaPack + filesPack + editPack + systemPack + appsPack + displayPack + sessionPack + sessionShowPack + filesRecentPack + finderDockPack

    public static func action(id: String) -> CompanionAction? {
        all.first { $0.id == id }
    }

    public static func isKnown(_ id: String) -> Bool {
        action(id: id) != nil
    }
}
