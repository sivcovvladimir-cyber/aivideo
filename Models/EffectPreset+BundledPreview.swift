import UIKit

extension EffectPreset {
    /// Имя изображения в Asset Catalog для **локального** постера превью (без сети).
    /// Правило: `effect_preview_<slug>` с дефисами как в API, заменёнными на `_` (имена ассетов без `-` проще в каталоге).
    /// Пример: slug `love-punch` → ассет `effect_preview_love_punch`.
    var effectPreviewBundledAssetName: String {
        let token = slug
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let safe = token.isEmpty ? "id_\(id)" : token
        return "effect_preview_\(safe)"
    }

    /// Картинка из бандла, если в каталоге есть Image Set с именем `effectPreviewBundledAssetName`; иначе `nil` → `PreviewMediaView` возьмёт `previewImageURL`.
    func bundledPreviewUIImage() -> UIImage? {
        UIImage(named: effectPreviewBundledAssetName)
    }
}
