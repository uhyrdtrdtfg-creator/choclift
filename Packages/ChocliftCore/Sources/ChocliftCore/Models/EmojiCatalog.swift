import Foundation

public struct EmojiCategory: Identifiable, Sendable {
    public let id: String
    public let titleZH: String
    public let titleEN: String
    public let icon: String
    public let emojis: [String]

    public func title(in lang: AppLanguage) -> String {
        L10n.tr(titleZH, titleEN, language: lang)
    }
}

public enum EmojiCatalog {
    public static let categories: [EmojiCategory] = [
        EmojiCategory(
            id: "popular",
            titleZH: "热门常用",
            titleEN: "Popular",
            icon: "⭐️",
            emojis: [
                "👍", "🔥", "✨", "❤️", "😂", "🙌", "🚀", "🍫",
                "✅", "🎉", "👀", "🙏", "💯", "⚡️", "🥳", "🫶",
                "😎", "🤔", "💡", "🎯", "📌", "👏", "🤝", "🥹"
            ]
        ),
        EmojiCategory(
            id: "faces",
            titleZH: "表情情绪",
            titleEN: "Smileys",
            icon: "😀",
            emojis: [
                "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂",
                "🙂", "😉", "😊", "😇", "🥰", "😍", "🤩", "😘",
                "😋", "😜", "🤪", "🤨", "🧐", "🤓", "😎", "🥳",
                "😏", "😒", "🫠", "😮", "🤯", "🫡", "😴", "🥶"
            ]
        ),
        EmojiCategory(
            id: "hands",
            titleZH: "手势互动",
            titleEN: "Hands",
            icon: "👋",
            emojis: [
                "👋", "🤚", "🖐️", "✋", "👌", "🤌", "🤏", "✌️",
                "🤞", "🫰", "🤟", "🤘", "🤙", "👈", "👉", "👆",
                "👇", "☝️", "👍", "👎", "✊", "👊", "👏", "🙌",
                "🫶", "👐", "🤲", "🤝", "🙏", "✍️", "💪", "🫡"
            ]
        ),
        EmojiCategory(
            id: "work",
            titleZH: "工作与效率",
            titleEN: "Workflow",
            icon: "💼",
            emojis: [
                "✅", "☑️", "✔️", "❌", "⚠️", "🚨", "📌", "📍",
                "📎", "📝", "📅", "📆", "📊", "📈", "📉", "🗂️",
                "📁", "🔍", "🔒", "🔑", "💡", "🎯", "🏆", "🥇",
                "⏰", "⏳", "📣", "💬", "🧠", "🛠️", "⚙️", "🧪"
            ]
        ),
        EmojiCategory(
            id: "tech",
            titleZH: "科技与创意",
            titleEN: "Tech & Creative",
            icon: "💻",
            emojis: [
                "💻", "🖥️", "📱", "⌨️", "🖱️", "🕹️", "🎧", "🎤",
                "🎬", "🎨", "📸", "🎥", "🎵", "🎸", "🚀", "🛸",
                "🤖", "👾", "🐛", "🧬", "🔮", "💎", "⚡️", "🌐"
            ]
        ),
        EmojiCategory(
            id: "sweet",
            titleZH: "可可与美食",
            titleEN: "Cocoa & Treats",
            icon: "🍫",
            emojis: [
                "🍫", "🍬", "🍭", "🍮", "🍯", "🍪", "🍩", "🧁",
                "🍰", "🎂", "🥐", "☕️", "🍵", "🧋", "🍓", "🍒",
                "🍑", "🍊", "🍋", "🍎", "🥑", "🍕", "🍔", "🥂"
            ]
        ),
        EmojiCategory(
            id: "arrows",
            titleZH: "箭头与符号",
            titleEN: "Arrows & Marks",
            icon: "➡️",
            emojis: [
                "⬆️", "↗️", "➡️", "↘️", "⬇️", "↙️", "⬅️", "↖️",
                "↕️", "↔️", "↩️", "↪️", "🔄", "➕", "➖", "➗",
                "❗️", "❓", "‼️", "⁉️", "♻️", "⚜️", "♾️", "⭐️"
            ]
        )
    ]

    public static let allUniqueEmojis: [String] = {
        var seen = Set<String>()
        var out: [String] = []
        for cat in categories {
            for e in cat.emojis where seen.insert(e).inserted {
                out.append(e)
            }
        }
        return out
    }()
}
