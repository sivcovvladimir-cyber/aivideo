import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Icon Type

/// Округление размера под физические пиксели: иначе 24 pt на Retina часто попадает между пикселями и штрихи «мажутся».
private func iconPixelAlignedSize(_ size: CGFloat) -> CGFloat {
    #if canImport(UIKit)
    let scale = UIScreen.main.scale
    guard scale > 0 else { return size }
    return (size * scale).rounded(.toNearestOrAwayFromZero) / scale
    #else
    return size
    #endif
}

enum IconType {
    case custom(String)           // Ассет из каталога (иллюстрации, watermark и т.п.)
    case sfSymbol(String)         // SF Symbol
}

// MARK: - Icon View

struct IconView: View {
    let icon: IconType
    let size: CGFloat
    let color: Color
    let renderingMode: Image.TemplateRenderingMode

    init(
        _ icon: IconType,
        size: CGFloat = 24,
        color: Color = AppTheme.Colors.textPrimary,
        renderingMode: Image.TemplateRenderingMode = .template
    ) {
        self.icon = icon
        self.size = size
        self.color = color
        self.renderingMode = renderingMode
    }

    var body: some View {
        let s = iconPixelAlignedSize(size)
        switch icon {
        case .custom(let name):
            Image(name)
                .renderingMode(renderingMode)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: s, height: s)
                .foregroundColor(color)
        case .sfSymbol(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .frame(width: s, height: s)
                .foregroundColor(color)
        }
    }
}

// MARK: - Convenience Initializers

extension IconView {
    // Поддержка legacy-имен иконок из старого xcassets: если ассета нет, используем ближайший SF Symbol (как в storecards).
    // Legacy-имена с другого клиента: маппинг в SF Symbol; корзина — контурный `trash` (не filled), чтобы совпадать с привычной иконкой списков.
    private static let legacyAliasToSFSymbol: [String: String] = [
        // Один и тот же SF Symbol для неактивного/активного таба «Эффекты» — различие только цветом в `BottomNavigationBar` (пара sparkle/sparkles давала разные иконки).
        "Home": "sparkles",
        "Home Fill": "sparkles",
        "Gallery": "photo",
        "Gallery Fill": "photo.fill",
        "Plus": "plus",
        "Settings": "gearshape",
        "Arrow - Left": "chevron.left",
        "Arrow - Right": "chevron.right",
        "Delete": "trash",
        "Discovery": "magnifyingglass",
        "Crown": "crown",
        "Crown Group": "crown",
        "Moon": "moon.fill",
        "Sun": "sun.max.fill",
        "Filter": "magnifyingglass",
        "Star Fill": "star.fill",
        "Star": "star",
        "Shair": "square.and.arrow.up",
        "Download": "arrow.down.to.line",
        "Balls": "circle.grid.3x3.fill",
        "Upload": "square.and.arrow.up",
        "Message": "envelope",
        "Paper": "doc.text.fill",
        "Lock": "lock.fill",
        "Mail": "envelope",
        "Tick Square": "checkmark.circle.fill",
        "Close Square": "xmark.circle.fill"
    ]

    // Умный конструктор — сам определяет тип иконки (логика как в storecards/IconView.swift).
    init(
        _ name: String,
        size: CGFloat = 24,
        color: Color = AppTheme.Colors.textPrimary,
        renderingMode: Image.TemplateRenderingMode = .template
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sfSymbols = Set(["xmark"])

        if sfSymbols.contains(trimmed) {
            self.init(.sfSymbol(trimmed), size: size, color: color)
            return
        }

        #if canImport(UIKit)
        if UIImage(named: trimmed) != nil {
            self.init(.custom(trimmed), size: size, color: color, renderingMode: renderingMode)
            return
        }
        #endif

        if let symbol = Self.legacyAliasToSFSymbol[trimmed] {
            self.init(.sfSymbol(symbol), size: size, color: color)
            return
        }

        // Строки вида `exclamationmark.triangle` / плейсхолдеры галереи — уже имена SF Symbol, ассета в каталоге нет.
        if trimmed.range(of: "^[a-z0-9.]+$", options: .regularExpression) != nil {
            self.init(.sfSymbol(trimmed), size: size, color: color)
            return
        }

        self.init(.sfSymbol("questionmark.circle"), size: size, color: color)
    }
}

// MARK: - View Extension for Easy Usage

extension View {
    func icon(
        _ name: String,
        size: CGFloat = 24,
        color: Color = AppTheme.Colors.textPrimary
    ) -> some View {
        self.overlay(
            IconView(name, size: size, color: color)
        )
    }
}
