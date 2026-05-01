import Foundation

/// Curated list of common BCP-47 language codes that YouTube generally supports
/// for subtitle tracks. Used by Settings → Дополнительно → Приоритет языков
/// to populate the "add language" dropdown so users don't have to type codes
/// from memory.
enum Languages {
    struct Entry: Hashable, Identifiable {
        let code: String
        let nameRu: String
        var id: String { code }
        var displayName: String {
            "\(nameRu) — \(code)"
        }
    }

    /// Sorted alphabetically by Russian name.
    static let common: [Entry] = [
        Entry(code: "ar", nameRu: "Арабский"),
        Entry(code: "bn", nameRu: "Бенгальский"),
        Entry(code: "bg", nameRu: "Болгарский"),
        Entry(code: "vi", nameRu: "Вьетнамский"),
        Entry(code: "nl", nameRu: "Голландский"),
        Entry(code: "el", nameRu: "Греческий"),
        Entry(code: "ka", nameRu: "Грузинский"),
        Entry(code: "da", nameRu: "Датский"),
        Entry(code: "he", nameRu: "Иврит"),
        Entry(code: "id", nameRu: "Индонезийский"),
        Entry(code: "es", nameRu: "Испанский"),
        Entry(code: "es-ES", nameRu: "Испанский (Испания)"),
        Entry(code: "es-MX", nameRu: "Испанский (Мексика)"),
        Entry(code: "it", nameRu: "Итальянский"),
        Entry(code: "kk", nameRu: "Казахский"),
        Entry(code: "ca", nameRu: "Каталанский"),
        Entry(code: "zh", nameRu: "Китайский"),
        Entry(code: "zh-CN", nameRu: "Китайский (Упрощённый)"),
        Entry(code: "zh-TW", nameRu: "Китайский (Традиционный)"),
        Entry(code: "ko", nameRu: "Корейский"),
        Entry(code: "ms", nameRu: "Малайский"),
        Entry(code: "de", nameRu: "Немецкий"),
        Entry(code: "no", nameRu: "Норвежский"),
        Entry(code: "fa", nameRu: "Персидский"),
        Entry(code: "pl", nameRu: "Польский"),
        Entry(code: "pt", nameRu: "Португальский"),
        Entry(code: "pt-BR", nameRu: "Португальский (Бразилия)"),
        Entry(code: "pt-PT", nameRu: "Португальский (Португалия)"),
        Entry(code: "ro", nameRu: "Румынский"),
        Entry(code: "ru", nameRu: "Русский"),
        Entry(code: "ru-RU", nameRu: "Русский (Россия)"),
        Entry(code: "sr", nameRu: "Сербский"),
        Entry(code: "sk", nameRu: "Словацкий"),
        Entry(code: "sl", nameRu: "Словенский"),
        Entry(code: "th", nameRu: "Тайский"),
        Entry(code: "tr", nameRu: "Турецкий"),
        Entry(code: "uk", nameRu: "Украинский"),
        Entry(code: "ur", nameRu: "Урду"),
        Entry(code: "tl", nameRu: "Филиппинский"),
        Entry(code: "fi", nameRu: "Финский"),
        Entry(code: "fr", nameRu: "Французский"),
        Entry(code: "fr-FR", nameRu: "Французский (Франция)"),
        Entry(code: "fr-CA", nameRu: "Французский (Канада)"),
        Entry(code: "hi", nameRu: "Хинди"),
        Entry(code: "hr", nameRu: "Хорватский"),
        Entry(code: "cs", nameRu: "Чешский"),
        Entry(code: "sv", nameRu: "Шведский"),
        Entry(code: "et", nameRu: "Эстонский"),
        Entry(code: "ja", nameRu: "Японский"),
        Entry(code: "en", nameRu: "Английский"),
        Entry(code: "en-US", nameRu: "Английский (США)"),
        Entry(code: "en-GB", nameRu: "Английский (Великобритания)")
    ].sorted { $0.nameRu.localizedCompare($1.nameRu) == .orderedAscending }

    /// Lookup: given a code (possibly user-entered raw), return its display name.
    static func displayName(for code: String) -> String {
        if let match = common.first(where: { $0.code.lowercased() == code.lowercased() }) {
            return match.displayName
        }
        return code
    }
}
