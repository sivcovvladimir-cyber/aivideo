import Foundation

/// Строка PostgREST `style_categories` (если таблица есть в проекте); к каталогу `get_effects_home` не относится.
public struct SupabaseEffectCategoryRow: Identifiable, Codable {
    public let id: Int
    public let name: String
    public let sortOrder: Int?
    public let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortOrder = "sort_order"
        case isActive = "is_active"
    }
}
