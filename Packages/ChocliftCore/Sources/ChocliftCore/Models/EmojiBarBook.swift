import Foundation

public struct EmojiBarBook: Codable, Equatable, Hashable, Sendable {
    public static let slideCount = 8
    public static let emojisPerSlide = 8
    public static let totalCapacity = slideCount * emojisPerSlide
    public static let maxScalarsPerEmoji = 8

    public static let insertEventName = "emoji_bar_insert"
    public static let insertResultEventName = "emoji_bar_insert_result"
    public static let clearRequestEventName = "emoji_bar_clear_request"
    public static let editRequestEventName = "emoji_bar_edit_request"

    public static let empty = EmojiBarBook()

    public var slides: [[String]]

    private enum CodingKeys: String, CodingKey {
        case slides
    }

    public init(slides: [[String]] = []) {
        self.slides = Self.sanitize(slides)
    }

    public init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(), singleValue.decodeNil() {
            self.slides = Self.makeEmptySlides()
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSlides = try container.decodeIfPresent([[String?]].self, forKey: .slides) ?? []
        self.slides = Self.sanitizeOptionalSlides(rawSlides)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.sanitize(slides), forKey: .slides)
    }

    /// Validates a single emoji slot value: trims whitespace/newlines, rejects empty strings,
    /// requires a single extended grapheme cluster, and rejects strings longer than 8 Unicode scalars after trim.
    public static func validateEmoji(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count == 1,
              trimmed.unicodeScalars.count <= maxScalarsPerEmoji else {
            return nil
        }
        return trimmed
    }

    public static func isValidEmoji(_ raw: String) -> Bool {
        validateEmoji(raw) != nil
    }

    public static func isValidSlot(slide: Int, index: Int) -> Bool {
        (0..<slideCount).contains(slide) && (0..<emojisPerSlide).contains(index)
    }

    public static func slideTitle(for slide: Int, in language: AppLanguage = .system) -> String {
        let displayNumber = max(1, slide + 1)
        return L10n.tr("幻灯片 \(displayNumber)", "Slide \(displayNumber)", language: language)
    }

    @discardableResult
    public mutating func set(slide: Int, index: Int, emoji: String) -> Bool {
        guard Self.isValidSlot(slide: slide, index: index),
              let validEmoji = Self.validateEmoji(emoji) else {
            return false
        }
        if slides.count != Self.slideCount || slides[slide].count != Self.emojisPerSlide {
            sanitize()
        }
        slides[slide][index] = validEmoji
        return true
    }

    public mutating func clear(slide: Int) {
        if slides.count != Self.slideCount {
            sanitize()
        }
        guard (0..<Self.slideCount).contains(slide) else {
            return
        }
        slides[slide] = Self.makeEmptySlide()
    }

    @discardableResult
    public mutating func clear(slide: Int, index: Int) -> Bool {
        clearSlot(slide: slide, index: index)
    }

    @discardableResult
    public mutating func clearSlot(slide: Int, index: Int) -> Bool {
        guard Self.isValidSlot(slide: slide, index: index) else {
            return false
        }
        if slides.count != Self.slideCount || slides[slide].count != Self.emojisPerSlide {
            sanitize()
        }
        slides[slide][index] = ""
        return true
    }

    public mutating func sanitize() {
        slides = Self.sanitize(slides)
    }

    public func sanitized() -> EmojiBarBook {
        EmojiBarBook(slides: slides)
    }

    public func emoji(slide: Int, index: Int) -> String? {
        guard (0..<slides.count).contains(slide),
              (0..<slides[slide].count).contains(index) else {
            return nil
        }
        return Self.validateEmoji(slides[slide][index])
    }

    public func isSlideEmpty(_ slide: Int) -> Bool {
        guard (0..<slides.count).contains(slide) else {
            return true
        }
        return slides[slide].allSatisfy { Self.validateEmoji($0) == nil }
    }

    public var isEmpty: Bool {
        (0..<slides.count).allSatisfy { isSlideEmpty($0) }
    }

    public var totalSlotCount: Int {
        slides.reduce(0) { $0 + $1.count }
    }

    public var filledCount: Int {
        slides.reduce(0) { partial, slide in
            partial + slide.reduce(0) { $0 + (Self.validateEmoji($1) != nil ? 1 : 0) }
        }
    }

    public static func sanitize(_ rawSlides: [[String]]) -> [[String]] {
        sanitizeOptionalSlides(rawSlides.map { $0.map { Optional($0) } })
    }

    private static func sanitizeOptionalSlides(_ rawSlides: [[String?]]) -> [[String]] {
        var result: [[String]] = []
        result.reserveCapacity(slideCount)

        for rawSlide in rawSlides.prefix(slideCount) {
            var normalizedSlide: [String] = []
            normalizedSlide.reserveCapacity(emojisPerSlide)

            for rawEntry in rawSlide.prefix(emojisPerSlide) {
                if let rawEntry, let valid = validateEmoji(rawEntry) {
                    normalizedSlide.append(valid)
                } else {
                    normalizedSlide.append("")
                }
            }

            while normalizedSlide.count < emojisPerSlide {
                normalizedSlide.append("")
            }
            result.append(normalizedSlide)
        }

        while result.count < slideCount {
            result.append(makeEmptySlide())
        }

        return result
    }

    private static func makeEmptySlide() -> [String] {
        Array(repeating: "", count: emojisPerSlide)
    }

    private static func makeEmptySlides() -> [[String]] {
        Array(repeating: makeEmptySlide(), count: slideCount)
    }
}

public extension KeyedDecodingContainer {
    func decode(_ type: EmojiBarBook.Type, forKey key: Key) throws -> EmojiBarBook {
        try decodeIfPresent(type, forKey: key) ?? .empty
    }
}
