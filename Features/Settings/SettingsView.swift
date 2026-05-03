import SwiftUI
import Foundation
import UIKit

// Import ContactService

// Плитка как в списке настроек: `IconView` + ключ `Delete` (контурная корзина), 14 pt в квадрате 32×32.
private struct SettingsIconPlatter: View {
    let systemName: String
    /// Без явной подписки на `ThemeManager` плитка могла оставаться с цветами прежней темы: строка «Theme» обновлялась из‑за `themeManager` в родителе, остальные строки — нет.
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(AppTheme.Colors.cardBackground)
            .frame(width: 32, height: 32)
            .overlay(
                IconView(systemName, size: 14, color: AppTheme.Colors.textPrimary)
            )
    }
}

/// Подпись версии и отступы скролла относительно плавающего `BottomNavigationBar` (~капсула 68 + отступы + небольшой зазор).
private enum SettingsVersionRevealLayout {
    /// Нижний `contentInset` у `UIScrollView`: место под капсулу таббара (как на главной/галерее).
    static let tabBarScrollClearance: CGFloat = 88
    /// В покое строка версии сильнее утоплена за нижний край.
    static let versionRestDownwardOffset: CGFloat = 86
    /// Мёртвая зона для лёгкой пружины у нижней границы: до этого порога версия полностью скрыта.
    static let revealStartRubberThreshold: CGFloat = 36
    static let opacityRubberDivisor: CGFloat = 12
    /// Небольшой зазор в контенте над inset (не «километр»).
    static let contentTailAboveTabBar: CGFloat = 2
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    /// Цвета из AppTheme завязаны на ThemeManager без SwiftUI-dependency; без наблюдения тело экрана не инвалидируется при toggle темы (таббар уже наблюдал ThemeManager отдельно).
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var tokenWallet = TokenWalletService.shared
    @StateObject private var shareService = ShareService()
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showLanguageSelector = false
    @State private var showClearGalleryConfirmation = false
    /// Размер папки локальной галереи (`GeneratedImages`); справа у «Очистить галерею», как у языка.
    @State private var galleryFolderSizeLabel: String = "…"
    /// Увеличиваем после очистки галереи, если число элементов не изменилось, но объём на диске уже другой.
    @State private var galleryFolderSizeRevision: Int = 0

    private var bundleShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
    
    // Debug Mode
    @State private var debugPassword = ""
    @State private var debugTapCount = 0
    /// Размер кэша, который снимает «Очистить кэш» (ImageCache + превью эффектов на диске); справа от строки как у языка/темы.
    @State private var debugClearableCacheSizeLabel: String = "…"
    @State private var lastTapTime: Date = Date()
    /// Насколько нижний край контента ушёл ниже низа вьюпорта скролла (rubber-band снизу); 0 — покой, отпружинивает вместе с UIScrollView.
    @State private var settingsScrollBottomRubberband: CGFloat = 0
    
    var body: some View {
        ZStack {
            // Background color from AppTheme
            AppTheme.Colors.background
                .ignoresSafeArea()
                .onAppear {
                    // Report settings opened event
                    Task {
                        await AppAnalyticsService.shared.reportSettingsOpened()
                    }
                }
            
            VStack(spacing: 0) {
                // Header
                TopNavigationBar(
                    title: "settings".localized,
                    showBackButton: false,
                    customRightContent: AnyView(
                        ProStatusBadge(
                            tokenBalance: tokenWallet.balance,
                            action: {
                                appState.presentPaywallFullscreen()
                            }
                        )
                    ),
                    backgroundColor: AppTheme.Colors.background
                )
                .onTapGesture {
                    handleDebugTap()
                }
                
                SettingsNativeScrollView(
                    bottomOverscroll: $settingsScrollBottomRubberband,
                    scrollBottomInsetForTabBar: SettingsVersionRevealLayout.tabBarScrollClearance
                ) {
                    VStack(alignment: .leading, spacing: 24) {
                        // Плашка PRO / «Нужно больше генераций» — для всех; у према другой заголовок
                        ZStack {
                            AppTheme.Colors.primaryGradient
                            
                            Group {
                                Circle().fill(.white).frame(width: 3.11, height: 3.11).offset(x: -150, y: -20)
                                Circle().fill(.white).frame(width: 0.89, height: 0.89).offset(x: -140, y: 15)
                                Circle().fill(.white).frame(width: 4.44, height: 4.44).offset(x: -130, y: -25)
                                Circle().fill(.white).frame(width: 2.22, height: 2.22).offset(x: -120, y: 10)
                                Circle().fill(.white).frame(width: 2.22, height: 2.22).offset(x: -110, y: -15)
                                Circle().fill(.white).frame(width: 0.89, height: 0.89).offset(x: -100, y: 20)
                            }
                            
                            HStack(spacing: 16) {
                                // Ассет из каталога (как раньше): полноцветная корона, не SF Symbol.
                                Image("Crown Group")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 72, height: 72)
                                
                                // Одна строка: при нехватке ширины шрифт плавно уменьшается (как minimumScaleFactor у UILabel), а не переносится.
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(appState.isProUser ? "need_more_generations".localized : "upgrade_to_pro".localized)
                                        .font(AppTheme.Typography.featureTitle)
                                        .fontWeight(.bold)
                                        .foregroundColor(AppTheme.Colors.onPrimaryText)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.80)
                                        .multilineTextAlignment(.leading)
                                    Text(appState.isProUser ? "buy_prem_pack".localized : "enjoy_all_features".localized)
                                        .font(AppTheme.Typography.bodySecondary)
                                        .tracking(0.20)
                                        .lineSpacing(0)
                                        .foregroundColor(AppTheme.Colors.onPrimaryText)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.85)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(AppTheme.Colors.onPrimaryText)
                            }
                            .padding(16)
                        }
                        // Фиксированная высота как раньше: minHeight давал разрастись блоку при переносе подзаголовка.
                        .frame(height: 88)
                        .clipped()
                        .cornerRadius(16)
                        .onTapGesture { appState.presentPaywallFullscreen() }
                        .themeAware()
                        .themeAnimation()
                        

                        
                        // General Section
            VStack(spacing: 24) {
                            // Section Header
                            HStack(spacing: 16) {
                    Text("general".localized)
                                    .font(AppTheme.Typography.sectionLabel)
                                    .tracking(0.20)
                                    .lineSpacing(19.60)
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                                
                                // Separator line
                                Rectangle()
                                    .fill(AppTheme.Colors.border)
                                    .frame(height: 0.5)
                            }
                            
                            // Settings Items
                            SettingItem(
                                systemName: "square.and.arrow.up",
                                title: "share_app".localized,
                                action: {
                                    shareService.shareApp()
                                }
                            )
                            
                            SettingItem(
                                systemName: "envelope",
                                title: "contact_us".localized,
                                action: {
                                    openContactForm()
                                }
                            )

                            // Слева как `SettingItem` (`listRowTitle` без scale); справа не трогаем — остаётся вторичный `body`, как до «улучшений».
                            HStack(spacing: 16) {
                                SettingsIconPlatter(systemName: "globe")
                                Text("language".localized)
                                    .font(AppTheme.Typography.listRowTitle)
                                    .lineSpacing(21.60)
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Text(AppLanguageSupport.nativeEndonym(for: appState.getCurrentLanguage()))
                                    .font(AppTheme.Typography.body)
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { showLanguageSelector = true }
                            .themeAware()
                            .themeAnimation()

                            // Theme toggle
                            HStack(spacing: 16) {
                                SettingsIconPlatter(systemName: themeManager.currentTheme == .light ? "moon" : "sun.max")

                                Text("theme".localized)
                                    .font(AppTheme.Typography.listRowTitle)
                                    .lineSpacing(21.60)
                                    .foregroundColor(AppTheme.Colors.textPrimary)

                                Spacer()

                                Text(themeManager.currentTheme.displayName)
                                    .font(AppTheme.Typography.body)
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                themeManager.toggleTheme()
                            }
                            .themeAware()
                            .themeAnimation()

                            HStack(spacing: 16) {
                                SettingsIconPlatter(systemName: "Delete")
                                Text("clear_gallery".localized)
                                    .font(AppTheme.Typography.listRowTitle)
                                    .lineSpacing(21.60)
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Text(galleryFolderSizeLabel)
                                    .font(AppTheme.Typography.body)
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                                    .lineLimit(1)
                                    .monospacedDigit()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showClearGalleryConfirmation = true
                            }
                            .themeAware()
                            .themeAnimation()
                        }
                        
                        // About Section
                        VStack(spacing: 24) {
                            // Section Header
                            HStack(spacing: 16) {
                    Text("info_legal".localized)
                                    .font(AppTheme.Typography.sectionLabel)
                                    .tracking(0.20)
                                    .lineSpacing(19.60)
                                    .foregroundColor(AppTheme.Colors.textSecondary)
                                
                                // Separator line
                                Rectangle()
                                    .fill(AppTheme.Colors.border)
                                    .frame(height: 0.5)
                            }
                            
                            SettingItem(
                                systemName: "doc.text",
                                title: "terms_of_service".localized,
                                action: {
                                    openTermsOfService()
                                }
                            )
                            
                            SettingItem(
                                systemName: "lock",
                                title: "privacy_policy".localized,
                                action: {
                                    openPrivacyPolicy()
                                }
                            )
                                    }
                        
                        // Debug section (только для тестирования)
                        VStack(spacing: 24) {

                            
                            // Debug Mode Section (только если включен дебаг режим)
                            if appState.isDebugModeEnabled {
                                Group {
                                // Debug Section Header
                                HStack(spacing: 16) {
                                    Text("Debug Mode")
                                        .font(AppTheme.Typography.sectionLabel)
                                        .tracking(0.20)
                                        .lineSpacing(19.60)
                                        .foregroundColor(AppTheme.Colors.textSecondary)
                                    
                                    // Separator line
                                    Rectangle()
                                        .fill(AppTheme.Colors.border)
                                        .frame(height: 0.5)
                                }

                                HStack(spacing: 16) {
                                    SettingsIconPlatter(systemName: "gearshape")
                                    Text("settings_clear_cache".localized)
                                        .font(AppTheme.Typography.listRowTitle)
                                        .lineSpacing(21.60)
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Text(debugClearableCacheSizeLabel)
                                        .font(AppTheme.Typography.body)
                                        .foregroundColor(AppTheme.Colors.textSecondary)
                                        .lineLimit(1)
                                        .monospacedDigit()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(AppTheme.Colors.textSecondary)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task {
                                        await NonGalleryMediaCacheCleaner.clearAll()
                                        await MainActor.run {
                                            alertMessage = "settings_clear_cache_success".localized
                                            showAlert = true
                                            appState.notificationManager.showSuccess("settings_clear_cache_success".localized)
                                            refreshDebugClearableCacheSizeLabel()
                                        }
                                    }
                                }
                                .onAppear {
                                    refreshDebugClearableCacheSizeLabel()
                                }
                                .themeAware()
                                .themeAnimation()
                                
                                SettingItem(
                                    systemName: "arrow.clockwise",
                                    title: "Force Reload Data",
                                    action: {
                                        appState.forceReloadData()
                                        alertMessage = "Data reloaded from server"
                                        showAlert = true
                                    }
                                )

                                // PRO Status Toggle
                                HStack(spacing: 20) {
                                    // Icon
                                    SettingsIconPlatter(systemName: "crown")
                                    
                                    // Title
                                    Text("PRO Status")
                                        .font(AppTheme.Typography.listRowTitle)
                                        .lineSpacing(21.60)
                                        .foregroundColor(AppTheme.Colors.textPrimary)
                                    
                                    Spacer()
                                    
                                    // Toggle
                                    Toggle("", isOn: Binding(
                                        get: { appState.isProUser },
                                        set: { newValue in
                                            if newValue {
                                                appState.isProUser = true
                                                AdaptyService.shared.isProUser = true
                                                UserDefaults.standard.set(true, forKey: AppState.debugProOverrideKey)
                                                UserDefaults.standard.set(true, forKey: "isProUser")
                                                appState.onBecamePro()
                                                appState.notificationManager.showSuccess("PRO status enabled")
                                            } else {
                                                appState.isProUser = false
                                                AdaptyService.shared.isProUser = false
                                                UserDefaults.standard.set(false, forKey: AppState.debugProOverrideKey)
                                                UserDefaults.standard.removeObject(forKey: "AdaptyProfile")
                                                UserDefaults.standard.removeObject(forKey: "isProUser")
                                                appState.notificationManager.showSuccess("PRO status disabled")
                                            }
                                        }
                                    ))
                                    .toggleStyle(
                                        RoundThumbSwitchToggleStyle(
                                            onTint: AppTheme.Colors.primary,
                                            offTrackTint: themeManager.currentTheme == .dark
                                                ? Color.white.opacity(0.22)
                                                : Color.black.opacity(0.1)
                                        )
                                    )
                                }
                                .contentShape(Rectangle())
                                .themeAware()
                                .themeAnimation()
                                

                                
                                SettingItem(
                                    systemName: "arrow.counterclockwise",
                                    title: "settings_debug_reset_tokens".localized,
                                    action: {
                                        // Debug: кошелёк в Keychain сбрасывается как при первом запуске, затем `sync` выставляет стартовый баланс из `PaywallConfig` / `GenerationCostCalculator`.
                                        tokenWallet.resetForDebug()
                                        appState.notificationManager.showSuccess("settings_debug_reset_tokens_success".localized)
                                    }
                                )
                                
                                SettingItem(
                                    systemName: "hand.wave",
                                    title: "Reset Onboarding Flag",
                                    action: {
                                        // Для регрессионной проверки онбординга сбрасываем флаг завершения и сразу возвращаем на экран онбординга.
                                        appState.hasCompletedOnboarding = false
                                        appState.currentScreen = .onboarding
                                        appState.notificationManager.showSuccess("Onboarding flag reset")
                                    }
                                )
                                
                                SettingItem(
                                    systemName: "Delete",
                                    title: "Clear Paywall Cache",
                                    action: {
                                        PaywallCacheManager.shared.clearCache()
                                        alertMessage = "Paywall cache cleared"
                                        showAlert = true
                                    }
                                )

                                SettingItem(
                                    systemName: "xmark.octagon",
                                    title: "Disable Debug Mode",
                                    action: {
                                        appState.disableDebugMode()
                                        appState.notificationManager.showSuccess("Debug mode disabled")
                                    }
                                )
                                }
                                // Подписки только пока секция Debug на экране — у обычного пользователя обход каталогов не стартует.
                                .onReceive(NotificationCenter.default.publisher(for: .nonGalleryPreviewCacheCleared)) { _ in
                                    refreshDebugClearableCacheSizeLabel()
                                }
                                .onReceive(NotificationCenter.default.publisher(for: .imageCacheCleared)) { _ in
                                    refreshDebugClearableCacheSizeLabel()
                                }
                            }

                        }

                        Color.clear
                            .frame(height: SettingsVersionRevealLayout.contentTailAboveTabBar)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                }
                // При смене состава секции Debug пересоздаём скролл, чтобы не оставался устаревший offset/inset.
                .id(appState.isDebugModeEnabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    BottomNavigationBar()
                    // Поверх капсулы, `allowsHitTesting(false)` — тапы проходят в таббар. Малый bounce внизу не раскрывает версию (dead zone).
                    let revealRubber = max(0, settingsScrollBottomRubberband - SettingsVersionRevealLayout.revealStartRubberThreshold)
                    Text("v \(bundleShortVersion)")
                        .font(.footnote)
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 6)
                        .transaction { $0.animation = nil }
                        .offset(y: SettingsVersionRevealLayout.versionRestDownwardOffset - revealRubber)
                        .opacity(min(1, revealRubber / SettingsVersionRevealLayout.opacityRubberDivisor))
                        .allowsHitTesting(false)
                }
            }
        }
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .themeAware()
        .themeAnimation()
        .task(id: "\(appState.generatedMedia.count)|\(appState.currentLanguage)|\(galleryFolderSizeRevision)") {
            let bytes = await Task.detached(priority: .userInitiated) {
                GeneratedImageService.shared.estimatedGalleryFolderDiskBytes()
            }.value
            let label = Self.formatByteCountForSettingsRow(bytes)
            await MainActor.run {
                galleryFolderSizeLabel = label
            }
        }
        .onChange(of: appState.currentLanguage) { _, _ in
            refreshDebugClearableCacheSizeLabel()
        }
        .onChange(of: appState.isDebugModeEnabled) { _, enabled in
            settingsScrollBottomRubberband = 0
            if enabled {
                refreshDebugClearableCacheSizeLabel()
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Info"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
        .alert(
            "clear_gallery".localized,
            isPresented: $showClearGalleryConfirmation
        ) {
            Button("cancel".localized, role: .cancel) {}
            Button("clear_gallery_button".localized, role: .destructive) {
                clearGalleryKeepingFavorites()
            }
        } message: {
            Text("clear_gallery_message".localized)
        }
        .sheet(isPresented: $showLanguageSelector) {
            LanguageSelectorView(appState: appState)
        }
    }
    
    // MARK: - Helper Methods
    
    @State private var contactMessage = ""
    
    private func openTermsOfService() {
        if let urlString = ConfigurationManager.shared.getValue(for: .termsOfServiceURL),
           let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }
    
    private func openPrivacyPolicy() {
        if let urlString = ConfigurationManager.shared.getValue(for: .privacyPolicyURL),
           let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }
    
    private func openContactForm() {
        let config = DynamicModalConfig(
            title: "contact_us".localized,
            description: "contact_description".localized,
            primaryButtonTitle: "send".localized,
            secondaryButtonTitle: "cancel".localized,
            iconName: "envelope.fill",
            primaryAction: {
                // This will be handled by inputAction
            },
            secondaryAction: {
                // User cancelled
            },
            showInputField: true,
            inputFieldType: .multiLine(placeholder: "contact_message_placeholder".localized),
            inputText: .constant(""),
            inputAction: { message in
                // Отправляем сообщение через ContactService
                ContactService.shared.submitContactForm(message: message) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success:
                            self.appState.notificationManager.showSuccess("contact_success_message".localized)
                            self.appState.dynamicModalManager?.dismissModal()
                        case .failure(let error):
                            self.appState.notificationManager.showError("error_contact_send_failed".localized(with: error.localizedDescription))
                        }
                    }
                }
            },
            inputValidationError: { errorMessage in
                appState.notificationManager.showError(errorMessage)
            },
            allowDismissOnBackgroundTap: true
        )
        
        appState.dynamicModalManager?.showModal(with: config)
    }
    
    // MARK: - Debug Mode

    /// Обход только двух небольших каталогов кэша на `.utility`; для не-debug — мгновенный выход, без влияния на прод.
    private func refreshDebugClearableCacheSizeLabel() {
        guard appState.isDebugModeEnabled else { return }
        Task.detached(priority: .utility) {
            let bytes = NonGalleryMediaCacheCleaner.estimatedDiskBytesBeforeClear()
            let label = Self.formatByteCountForSettingsRow(bytes)
            await MainActor.run {
                debugClearableCacheSizeLabel = label
            }
        }
    }

    private static func formatByteCountForSettingsRow(_ bytes: Int64) -> String {
        let lang = UserDefaults.standard.string(forKey: "app_language") ?? "en"
        let locale = AppLanguageSupport.locale(forAppLanguageCode: lang)
        // У `ByteCountFormatter` нет `locale` в Swift API; `ByteCountFormatStyle` даёт KB/MB под выбранный `app_language`.
        // Без `spellsOutZero: false` в части локалей (en, fr и др.) ноль пишется словом («Zero», «Zéro»), а не цифрой.
        let style = ByteCountFormatStyle(style: .file, allowedUnits: [.kb, .mb, .gb], spellsOutZero: false).locale(locale)
        return Int(bytes).formatted(style)
    }

    private func handleDebugTap() {
        let currentTime = Date()
        let timeDifference = currentTime.timeIntervalSince(lastTapTime)
        
        // Сброс счетчика если прошло больше 3 секунд
        if timeDifference > 3.0 {
            debugTapCount = 0
        }
        
        debugTapCount += 1
        lastTapTime = currentTime
        
        // Если достигли 10 тапов за 3 секунды
        if debugTapCount >= 10 {
            debugTapCount = 0
            showDebugPasswordModal()
        }
    }
    
    private func showDebugPasswordModal() {
        let config = DynamicModalConfig.passwordInput(
            title: "Debug Mode",
            description: "Enter debug password to access developer features",
            placeholder: "Enter password",
            inputText: $debugPassword,
            primaryAction: { password in
                if appState.verifyDebugPassword(password) {
                    appState.enableDebugMode()
                    appState.notificationManager.showSuccess("Debug mode enabled")
                    // Закрываем модальное окно только при успешной авторизации
                    appState.dynamicModalManager?.dismissModal()
                } else {
                    appState.notificationManager.showError("Invalid password")
                }
            },
            secondaryAction: {
                // User cancelled password input
            },
            validationError: { errorMessage in
                appState.notificationManager.showError(errorMessage)
            }
        )
        
        appState.dynamicModalManager?.showModal(with: config)
    }

    private func clearGalleryKeepingFavorites() {
        let favoriteIdsKey = "gallery_favorite_media_ids"
        let rawFavorites = UserDefaults.standard.string(forKey: favoriteIdsKey) ?? ""
        let favoriteIds = Set(rawFavorites.split(separator: ",").map(String.init))

        GeneratedImageService.shared.clearGeneratedImages(keepingFavoriteIds: favoriteIds)
        ImageDownloader.shared.clearCache()
        GalleryThumbnailCache.clear()

        appState.generatedMedia = GeneratedImageService.shared.loadGeneratedImages()
        galleryFolderSizeRevision += 1

        alertMessage = "clear_gallery_success".localized
        showAlert = true
    }

}

struct SettingItem: View {
    let systemName: String
    let title: String
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 16) {
            SettingsIconPlatter(systemName: systemName)

            Text(title)
                .font(AppTheme.Typography.listRowTitle)
                .lineSpacing(21.60)
                .foregroundColor(AppTheme.Colors.textPrimary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
        .themeAware()
        .themeAnimation()
    }
}

struct LanguageSelectorView: View {
    @Environment(\.dismiss) private var dismiss
    let appState: AppState

    /// Все локали из бандла; русский в конце списка по продуктовому запросу.
    private static let selectorCodes: [String] = ["en", "de", "es", "pt", "fr", "it", "ru"]

    var body: some View {
        ZStack {
            AppTheme.Colors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TopNavigationBar(
                    title: "language".localized,
                    titleAlignment: .center,
                    showBackButton: true,
                    backgroundColor: AppTheme.Colors.background,
                    onBackTap: { dismiss() }
                )

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(Self.selectorCodes.enumerated()), id: \.offset) { index, code in
                                if index > 0 {
                                    Rectangle()
                                        .fill(AppTheme.Colors.border)
                                        .frame(height: 0.5)
                                        .padding(.leading, 68)
                                        .allowsHitTesting(false)
                                }
                                LanguageOptionView(
                                    languageCode: code,
                                    languageName: AppLanguageSupport.nativeEndonym(for: code),
                                    isSelected: appState.getCurrentLanguage() == code,
                                    action: {
                                        appState.setLanguage(code)
                                        dismiss()
                                    }
                                )
                            }
                        }
                        .background(AppTheme.Colors.cardBackground)
                        .cornerRadius(16)
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .themeAware()
        .themeAnimation()
    }
}

// MARK: - Нативный скролл для нижней оттяжки

/// SwiftUI `ScrollView` не обновляет preference на каждый кадр rubber-band снизу — версия не появлялась. `UIScrollView` даёт стабильный «зазор» за контентом.
private struct SettingsNativeScrollView<Content: View>: UIViewRepresentable {
    @Binding var bottomOverscroll: CGFloat
    var scrollBottomInsetForTabBar: CGFloat
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(bottomOverscroll: $bottomOverscroll)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.alwaysBounceVertical = true
        scroll.bounces = true
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .automatic
        scroll.contentInset.bottom = scrollBottomInsetForTabBar
        scroll.verticalScrollIndicatorInsets.bottom = scrollBottomInsetForTabBar

        let host = UIHostingController(rootView: AnyView(content()))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(host.view)
        context.coordinator.hostingController = host

        let cg = scroll.contentLayoutGuide
        let fg = scroll.frameLayoutGuide
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: cg.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: cg.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: cg.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: cg.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: fg.widthAnchor)
        ])
        return scroll
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.bottomOverscroll = $bottomOverscroll
        context.coordinator.hostingController?.rootView = AnyView(content())
        if scrollView.contentInset.bottom != scrollBottomInsetForTabBar {
            scrollView.contentInset.bottom = scrollBottomInsetForTabBar
            scrollView.verticalScrollIndicatorInsets.bottom = scrollBottomInsetForTabBar
        }
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
        context.coordinator.refreshRubber(scrollView)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var bottomOverscroll: Binding<CGFloat>
        var hostingController: UIHostingController<AnyView>?
        private var lastPublished: CGFloat = -999

        init(bottomOverscroll: Binding<CGFloat>) {
            self.bottomOverscroll = bottomOverscroll
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            publish(scrollView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            publish(scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { publish(scrollView) }
        }

        func refreshRubber(_ scrollView: UIScrollView) {
            publish(scrollView)
        }

        private func publish(_ scrollView: UIScrollView) {
            let h = scrollView.bounds.height
            let ch = scrollView.contentSize.height
            guard h > 2, ch > 2 else {
                setRubber(0)
                return
            }
            let visibleBottom = scrollView.contentOffset.y + h - scrollView.adjustedContentInset.bottom
            let rubber = max(0, visibleBottom - ch)
            setRubber(rubber)
        }

        private func setRubber(_ v: CGFloat) {
            let eps: CGFloat = 0.25
            if abs(v - lastPublished) < eps, !(v == 0 && lastPublished > 1) { return }
            lastPublished = v
            bottomOverscroll.wrappedValue = v
        }
    }
}

struct LanguageOptionView: View {
    let languageCode: String
    let languageName: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            Text(languageName)
                .font(AppTheme.Typography.font(weight: isSelected ? .bold : .regular, size: 18))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            
            Spacer(minLength: 8)
            
            // Фиксированное место под галочку, как в списке debug — без «пустого» тапа справа.
            ZStack {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.primary)
                }
            }
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
        .themeAware()
        .themeAnimation()
    }
}
