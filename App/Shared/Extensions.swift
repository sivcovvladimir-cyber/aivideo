import Foundation
import SwiftUI
import UIKit
import CommonCrypto

extension String {
    /// Маркер отсутствия ключа в `Localizable.strings` (не должен встречаться в пользовательских переводах).
    private static let localizationMissingSentinel = "\u{E000}\u{E001}MISSING\u{E001}\u{E000}"

    /// Строка для языка из соответствующего `.lproj`; `nil`, если ключа нет в таблице.
    private static func localizedStringOrNil(key: String, language: String) -> String? {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        let raw = bundle.localizedString(forKey: key, value: localizationMissingSentinel, table: nil)
        return raw == localizationMissingSentinel ? nil : raw
    }

    /// Локализация под `app_language`; при отсутствии перевода — строка из **en**, затем системный fallback (ключ только в крайнем случае).
    var localized: String {
        let lang = UserDefaults.standard.string(forKey: "app_language") ?? "en"
        if let s = Self.localizedStringOrNil(key: self, language: lang) {
            return s
        }
        if lang != "en", let s = Self.localizedStringOrNil(key: self, language: "en") {
            return s
        }
        return NSLocalizedString(self, tableName: nil, bundle: Bundle.main, value: self, comment: "")
    }

    /// Returns the localized string with format arguments applied
    func localized(with arguments: CVarArg...) -> String {
        String(format: self.localized, arguments: arguments)
    }
}

// MARK: - Legacy Color Extensions (Deprecated)
extension Color {
    /// Custom purple color used throughout the app (from Figma design)
    /// @deprecated Используйте AppTheme.Colors.primary
    static var customPurple: Color { AppTheme.Colors.primary }
    
    /// App background color
    /// @deprecated Используйте AppTheme.Colors.background
    static var appBackground: Color { AppTheme.Colors.background }
}

// MARK: - UIDevice Extensions
extension UIDevice {
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
} 

extension Collection where Index == Int {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

extension UIImage {
    /// Создает копию изображения с заданной прозрачностью
    func withAlpha(_ alpha: CGFloat) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        defer { UIGraphicsEndImageContext() }
        
        guard UIGraphicsGetCurrentContext() != nil else { return nil }
        
        draw(in: CGRect(origin: .zero, size: size))
        
        return UIGraphicsGetImageFromCurrentImageContext()
    }
    
    /// Добавляет тёмный вотермарк по всему изображению (мелкая сетка, как на фотостоках)
    func addWatermark() -> UIImage? {
        let appName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "AI Video"
        let watermarkSize = CGSize(width: size.width, height: size.height)
        
        UIGraphicsBeginImageContextWithOptions(watermarkSize, false, 0.0)
        defer { UIGraphicsEndImageContext() }
        
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        
        draw(in: CGRect(origin: .zero, size: watermarkSize))
        
        let fontSize: CGFloat = 32
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: UIColor.black.withAlphaComponent(0.1)
        ]
        
        // Используем брендовый watermark-ассет и сохраняем текущую "сеточную" логику размещения.
        let watermarkAsset = UIImage(named: "Watermark") ?? UIImage(named: "watermark")
        let tileBaseSize: CGSize = {
            guard let watermarkAsset, watermarkAsset.size.width > 0, watermarkAsset.size.height > 0 else {
                return (appName as NSString).size(withAttributes: textAttributes)
            }
            let targetWidth = max(120, min(watermarkSize.width, watermarkSize.height) * 0.24)
            let ratio = watermarkAsset.size.height / watermarkAsset.size.width
            return CGSize(width: targetWidth, height: targetWidth * ratio)
        }()
        let stepX = tileBaseSize.width * 1.5
        let stepY = tileBaseSize.height * 1.25
        let angle = -30.0 * CGFloat.pi / 180.0
        let margin: CGFloat = 20
        
        var row: Int = 0
        var y: CGFloat = margin
        while y < watermarkSize.height + stepY {
            let offsetX = (row % 2 == 0) ? CGFloat(0) : stepX / 2
            var x: CGFloat = margin - stepX + offsetX
            var column: Int = 0
            while x < watermarkSize.width + stepX {
                // Смещаем каждый следующий watermark немного выше предыдущего, чтобы избежать ровных горизонтальных линий.
                let columnRise = CGFloat(column) * tileBaseSize.height * 0.35
                ctx.saveGState()
                ctx.translateBy(x: x, y: y - columnRise)
                ctx.rotate(by: angle)
                if let watermarkAsset {
                    watermarkAsset.draw(in: CGRect(origin: .zero, size: tileBaseSize), blendMode: .normal, alpha: 0.3)
                } else {
                    (appName as NSString).draw(at: .zero, withAttributes: textAttributes)
                }
                ctx.restoreGState()
                x += stepX
                column += 1
            }
            y += stepY
            row += 1
        }
        
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    /// Длинная сторона не больше `maxLongSide` — PixVerse и сохранение черновика без лишнего веса.
    func downscaled(maxLongSide: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxLongSide else { return self }

        let scale = maxLongSide / longestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

// MARK: - String Extensions

extension String {
    /// Создает SHA-512 хеш строки
    func sha512() -> String {
        let data = Data(self.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA512(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
} 