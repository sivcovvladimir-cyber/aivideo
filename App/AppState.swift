import Foundation
import Combine
import SwiftUI

// Глобальное состояние приложения и подписки живут на главном акторе — совместимо с Swift 6 и @MainActor-синглтонами (Adapty).
@MainActor
final class AppState: ObservableObject {
    // MARK: - Singleton
    static let shared = AppState()

    /// Куда вести назад с экрана пресета (главная каталога или сетка «View all»).
    enum EffectDetailDismissDestination: Equatable {
        case effectsHome
        case effectsBrowse(EffectsHomeSection)
    }
    
    enum Screen: Equatable {
        case splash, onboarding, effectsHome
        /// Полный список эффектов категории (из «View all» на главной).
        case effectsSectionBrowse(EffectsHomeSection)
        case effectDetail, generation, gallery, settings
    }
    
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("app_language") private var _appLanguage: String = "en"
    
    @Published var currentLanguage: String = "en"
    
    // MARK: - Published Properties
    
    @Published var currentScreen: Screen = .splash
    /// Промпт, режим, пиллы видео/фото и опциональное референс-фото — восстанавливаются при возврате на таб «Создать», пока процесс не убит.
    @Published var generationPromptScreenDraft: GenerationPromptScreenDraft = .initial

    func replaceGenerationPromptScreenDraft(_ draft: GenerationPromptScreenDraft) {
        generationPromptScreenDraft = draft
    }

    // MARK: - Сессионный снимок Supabase (один раз при старте процесса)

    enum SessionRemoteBootstrapPhase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// Фаза загрузки RPC `get_effects_home` на сплеше; после `.ready` повторных запросов к Supabase для каталога нет (до `retry…` или перезапуска).
    @Published private(set) var sessionRemoteBootstrapPhase: SessionRemoteBootstrapPhase = .idle
    @Published private(set) var sessionEffectsHomePayload: EffectsHomePayload?

    private var sessionBootstrapTask: Task<Void, Never>?

    /// Один полёт на запуск приложения; повторные вызовы ждут тот же `Task`.
    func ensureSessionRemoteDataAtLaunch() async {
        if case .ready = sessionRemoteBootstrapPhase { return }
        if let sessionBootstrapTask {
            await sessionBootstrapTask.value
            return
        }
        let task = Task { @MainActor in
            defer { self.sessionBootstrapTask = nil }
            self.sessionRemoteBootstrapPhase = .loading
            do {
                let payload = try await SupabaseSessionBootstrap.loadSessionSnapshot()
                self.sessionEffectsHomePayload = payload
                payload.debugLogSummary(source: "appstate-session-memory")
                self.sessionRemoteBootstrapPhase = .ready
                try? EffectsHomePayloadDiskCache.save(payload)
            } catch {
                if self.sessionEffectsHomePayload == nil {
                    self.sessionRemoteBootstrapPhase = .failed(error.localizedDescription)
                } else {
                    // Ошибка фонового обновления при уже показанном кэше — оставляем последний успешный снимок.
                    self.sessionRemoteBootstrapPhase = .ready
                }
            }
        }
        sessionBootstrapTask = task
        await task.value
    }

    /// Повторная попытка после ошибки на сплее / экране эффектов (снова ходим в Supabase один раз).
    func retrySessionRemoteBootstrap() async {
        sessionBootstrapTask?.cancel()
        sessionBootstrapTask = nil
        sessionRemoteBootstrapPhase = .idle
        sessionEffectsHomePayload = nil
        EffectsHomePayloadDiskCache.clear()
        await ensureSessionRemoteDataAtLaunch()
    }

    /// Полноэкранный paywall поверх текущего маршрута (после закрытия остаёмся на том же экране).
    @Published var isPaywallOverlayPresented: Bool = false
    @Published var isProUser: Bool = false {
        didSet {
            // Держим в курсе `TokenWalletService` и стартовый порядок инициализации (кошелёк до первого sink Adapty).
            UserDefaults.standard.set(isProUser, forKey: "isProUser")
        }
    }
    @Published var generatedMedia: [GeneratedMedia] = []
    /// После успешной генерации с открытого оверлея прогресса — показываем результат сразу (см. `GenerationJobService.finishSuccess`).
    @Published var generationSuccessDetailMedia: GeneratedMedia? = nil
    @Published var selectedEffectPreset: EffectPreset? = nil
    /// Порядок пресетов для горизонтальной карусели на Effect Detail (секция / «View all»); см. `docs/VIDEO_ARCHITECTURE.md` (detail carousel).
    @Published var effectDetailCarouselPresets: [EffectPreset] = []
    /// Референс-фото с деталей эффекта: переживает смену корневого экрана (табы, настройки и т.д.) до явного удаления пользователем.
    @Published var effectDetailDraftPhoto: UIImage?

    func setEffectDetailDraftPhoto(_ image: UIImage?) {
        effectDetailDraftPhoto = image
    }

    func clearEffectDetailDraftPhoto() {
        effectDetailDraftPhoto = nil
    }

    /// Запоминается при `openEffectDetail`, чтобы стрелка «назад» вернула не всегда на главную ленту.
    private(set) var effectDetailDismissDestination: EffectDetailDismissDestination = .effectsHome
    @Published var showNetworkAlert: Bool = false
    @Published var networkAlertMessage: String = ""
    
    // Состояния для модального окна оценки приложения
    @Published var showRatingModal: Bool = false

    // Лимиты генераций
    private let DEFAULT_FREE_GENERATIONS_LIMIT = 2

    /// Актуальный лимит бесплатных генераций (lifetime)
    var freeGenerationsLimit: Int {
        PaywallCacheManager.shared.paywallConfig?.logic.freeGenerationsLimit ?? DEFAULT_FREE_GENERATIONS_LIMIT
    }

    /// Майлстоуны по счёту генераций, после которых показывать запрос оценки (из конфига / Adapty).
    var showRatingAfterGenerations: [Int] {
        PaywallCacheManager.shared.paywallConfig?.logic.showRatingAfterGenerations ?? [2]
    }

    // MARK: - PRO generation tracking

    /// Кол-во использованных генераций в текущем периоде подписки
    @AppStorage("proGenerationsUsed") var proGenerationsUsed: Int = 0
    /// Начало текущего периода подписки (Unix timestamp); 0 = не инициализировано
    @AppStorage("proGenerationsPeriodStart") var proGenerationsPeriodStart: Double = 0
    /// Бонусные генерации из разовых пакетов
    @AppStorage("bonusGenerations") var bonusGenerations: Int = 0

    /// Лимит генераций для текущего плана подписки (из Adapty remote config).
    /// Берётся из общей мапы `generationLimits` по `vendorProductId`.
    /// Возвращает `nil` если лимит неизвестен → считаем неограниченным.
    /// В dev-режиме (PRO вкл, но Adapty не дал productId) берём лимит первого плана из конфига.
    var proGenerationsLimit: Int? {
        guard let limits = PaywallCacheManager.shared.paywallConfig?.generationLimits, !limits.isEmpty else { return nil }
        let currentPlanId = adaptyService.currentSubscriptionProductId ?? ""
        // Прямое совпадение
        if let limit = limits[currentPlanId] { return limit }
        // Частичное совпадение (на случай небольших расхождений идентификаторов)
        for (productId, limit) in limits {
            if currentPlanId.contains(productId) || productId.contains(currentPlanId) { return limit }
        }
        // Dev-режим: PRO вкл без реального productId — берём лимит первого подписочного плана
        if isProUser, let planIds = PaywallCacheManager.shared.paywallConfig?.planIds, let firstId = planIds.first {
            if let limit = PaywallCacheManager.shared.generationLimit(for: firstId) { return limit }
        }
        return nil
    }

    /// Осталось платных генераций (подписка + бонусные пакеты).
    /// Возвращает nil, если платных генераций нет (ни подписки, ни бонуса).
    var proGenerationsRemaining: Int? {
        // Сколько осталось по активной подписке
        let subscriptionRemaining: Int
        if isProUser, let limit = proGenerationsLimit {
            subscriptionRemaining = max(0, limit - proGenerationsUsed)
        } else {
            subscriptionRemaining = 0
        }
        let total = subscriptionRemaining + bonusGenerations
        return total > 0 ? total : nil
    }

    /// Ключ UserDefaults: майлстоуны, на которых уже показывали запрос оценки (храним как "2,10,50").
    private let ratingModalShownKey = "ratingModalShownAtGenerations"
    /// Пользователь нажал «Нравится» в окне оценки — не показываем запрос на следующих майлстоунах генераций.
    private static let userRatedAppPositiveKey = "user_rated_app_positive"

    private var hasUserRatedAppPositive: Bool {
        UserDefaults.standard.bool(forKey: Self.userRatedAppPositiveKey)
    }

    private func markUserRatedAppPositive() {
        UserDefaults.standard.set(true, forKey: Self.userRatedAppPositiveKey)
    }
    
    // Восстанавливаем AppStorage для основных данных
    @AppStorage("successfulGenerationsCount") var successfulGenerationsCount: Int = 0
    
    // Debug Mode
    @AppStorage("debug_mode_enabled") var isDebugModeEnabled: Bool = false
    /// Переключатель экспериментального промпт-билдера (model-specific JSON для Flux/Recraft, flat text для Ideogram).
    @AppStorage("experimental_prompt_builder") var useExperimentalPromptBuilder: Bool = false
    
    // Dynamic Modal Manager - будет установлен из RootView
    var dynamicModalManager: DynamicModalManager?
    

    
    // Error Manager для глобального управления ошибками
    let notificationManager = NotificationManager.shared
    
    // Adapty Service для управления подписками
    let adaptyService = AdaptyService.shared

    let tokenWallet = TokenWalletService.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Инициализируем язык
        currentLanguage = _appLanguage
        initializeLanguage()

        // Защита от обхода бесплатного лимита через переустановку приложения.
        //
        // UserDefaults (где хранится successfulGenerationsCount) очищается при удалении
        // приложения, поэтому без этой защиты пользователь мог бы снова получить
        // бесплатные генерации, просто удалив и переустановив приложение.
        //
        // Keychain в iOS переживает удаление приложения. Мы дублируем в нём
        // счётчик именно бесплатных генераций (не PRO). При каждом запуске берём
        // максимум из UserDefaults и Keychain — таким образом после переустановки
        // лимит восстанавливается из Keychain.
        let keychainCount = KeychainService.shared.getFreeGenerationsUsed()
        if keychainCount > successfulGenerationsCount {
            successfulGenerationsCount = keychainCount
            print("🔑 [AppState] Free gen count restored from Keychain: \(keychainCount)")
        }
        
        // Загружаем сохраненные сгенерированные изображения
        loadGeneratedMedia()
        
        // Добавляем тестовые данные для демонстрации галереи
        loadTestData()
        
        // Настраиваем наблюдатели для Adapty
        setupAdaptyObservers()

        setupTokenWalletObservers()
        
        // Настраиваем наблюдатель для сброса кэша изображений
        setupImageCacheObserver()
    }
    
    private func loadTestData() {
        // Для демонстрации empty state тестовые данные закомментированы
        // При необходимости можно раскомментировать для тестирования
        /*
        let testMedia = [
            GeneratedMedia(
                id: "test-1", 
                localPath: "placeholder-image", 
                createdAt: Date(), 
                styleId: 1, 
                userPhotoId: "user-1", 
                type: .image
            ),
            GeneratedMedia(
                id: "test-2", 
                localPath: "placeholder-image", 
                createdAt: Date().addingTimeInterval(-3600), 
                styleId: 2, 
                userPhotoId: "user-1", 
                type: .image
            )
        ]
        
        generatedMedia = testMedia
        */
    }
    
    @MainActor
    func loadInitialData() {
        print("📊 [AppState] === LOADING INITIAL DATA ===")
        print("📊 [AppState] Free generations used: \(successfulGenerationsCount)/\(freeGenerationsLimit)")

        // Обновляем статус подписки из Adapty
        updateProStatusFromAdapty()

        // Загружаем сохранённые медиа
        loadGeneratedMedia()

        // Предзагружаем данные Paywall без отрыва от MainActor (избегаем Sendable-захвата `self` в detached).
        Task(priority: .userInitiated) {
            await self.preloadPaywallData()
        }

        // Последний успешный каталог с диска: сплеш не ждёт сеть; свежий ответ подменит payload в фоне.
        if let cached = EffectsHomePayloadDiskCache.loadIfPresent() {
            sessionEffectsHomePayload = cached
        }

        // Сплеш: без кэша на диске — ждём Supabase + минимум 1.5 с; с кэшем — только минимум лого, сеть в фоне через `ensureSessionRemoteDataAtLaunch`.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let splashStarted = Date()
            let hasCachedCatalog = self.sessionEffectsHomePayload != nil
            if hasCachedCatalog {
                Task { await self.ensureSessionRemoteDataAtLaunch() }
            } else {
                await self.ensureSessionRemoteDataAtLaunch()
            }
            let elapsed = Date().timeIntervalSince(splashStarted)
            let minSplash: TimeInterval = 1.5
            if elapsed < minSplash {
                try? await Task.sleep(nanoseconds: UInt64((minSplash - elapsed) * 1_000_000_000))
            }
            if self.hasCompletedOnboarding {
                self.currentScreen = .effectsHome
                print("✅ [AppState] Onboarding done — showing Effects")
            } else {
                self.currentScreen = .onboarding
                print("✅ [AppState] Showing Onboarding")
            }
        }
    }
    
    // MARK: - Paywall Preloading
    
    /// Предзагружает данные Paywall в фоне
    private func preloadPaywallData() async {
        print("💰 [AppState] Начинаем предзагрузку данных Paywall")
        let success = await PaywallCacheManager.shared.loadAndCachePaywallDataAsync()
        await MainActor.run {
            self.tokenWallet.syncWithCurrentConfig()
            if success {
                print("✅ [AppState] Данные Paywall предзагружены")
            } else {
                print("⚠️ [AppState] Ошибка предзагрузки данных Paywall")
            }
        }
    }
    
    
    /// Загружает сохраненные сгенерированные изображения из локального хранилища
    func loadGeneratedMedia() {
        DispatchQueue.global(qos: .background).async {
            let savedMedia = GeneratedImageService.shared.loadGeneratedImages()

            DispatchQueue.main.async {
                let currentMedia = self.generatedMedia

                if currentMedia.isEmpty {
                    self.generatedMedia = savedMedia
                }
                // Миниатюры только при новом сохранении в Library, без массовой догенерации для старых файлов.
                GalleryThumbnailCache.warmup(media: self.generatedMedia)
            }
        }
    }
    
    // Mock-методы для подписки
    func setProUser(_ value: Bool) {
        isProUser = value
    }
    func toggleProUser() {
        isProUser.toggle()
    }
    
    // Методы для управления галереей
    func addGeneratedMedia(_ media: GeneratedMedia) {
        generatedMedia.insert(media, at: 0) // Добавляем в начало (новые первыми)
        
        // Обрабатываем успешную генерацию для оценки приложения
        handleSuccessfulGeneration()
    }

    func presentGenerationSuccessDetail(_ media: GeneratedMedia) {
        generationSuccessDetailMedia = media
    }

    func dismissGenerationSuccessDetail() {
        generationSuccessDetailMedia = nil
    }
    
    // Обработка успешной генерации
    private func handleSuccessfulGeneration() {
        successfulGenerationsCount += 1

        if isProUser {
            // PRO-генерации в Keychain не пишем: это не бесплатные генерации.
            // Если PRO-пользователь отпишется, он должен иметь возможность
            // воспользоваться своим бесплатным лимитом.
            if let limit = proGenerationsLimit, proGenerationsUsed < limit {
                proGenerationsUsed += 1
            } else if bonusGenerations > 0 {
                bonusGenerations -= 1
            }
            print("🎉 [AppState] PRO generation used: \(proGenerationsUsed)/\(proGenerationsLimit.map(String.init) ?? "∞"), bonus: \(bonusGenerations)")
        } else {
            // Не PRO: сначала тратим бонусные (оплаченные) пакеты, если они есть.
            if bonusGenerations > 0 {
                bonusGenerations -= 1
                print("🎉 [AppState] Bonus generation used (no active subscription). Bonus left: \(bonusGenerations)")
            } else {
                // Именно здесь расходуется БЕСПЛАТНАЯ генерация.
                // Дублируем счётчик в Keychain: это пожизненный лимит (не дневной),
                // Keychain переживает переустановку — защищаем лимит от обхода.
                KeychainService.shared.setFreeGenerationsUsed(successfulGenerationsCount)
                print("🎉 [AppState] Free generation used: \(successfulGenerationsCount)/\(freeGenerationsLimit)")
            }
        }

        // Показ запроса оценки на майлстоунах из конфига (локальный + override из Adapty).
        // Apple не даёт узнать, оставил ли пользователь отзыв; показываем раз на каждый майлстоун.
        // Если пользователь уже нажал «Нравится» — больше не беспокоим.
        let milestones = showRatingAfterGenerations
        let alreadyShown = ratingModalShownAtGenerations
        let countSnapshot = successfulGenerationsCount
        if !hasUserRatedAppPositive, milestones.contains(countSnapshot), !alreadyShown.contains(countSnapshot) {
            markRatingModalShown(at: countSnapshot)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                self.presentAppRatingPrompt()
            }
        }
    }

    /// Майлстоуны, на которых уже показывали запрос оценки (из UserDefaults).
    private var ratingModalShownAtGenerations: [Int] {
        let s = UserDefaults.standard.string(forKey: ratingModalShownKey) ?? ""
        return s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Сохранить, что запрос оценки показан на данном майлстоуне (повторно на нём не показываем).
    private func markRatingModalShown(at generationCount: Int) {
        var shown = ratingModalShownAtGenerations
        if !shown.contains(generationCount) {
            shown.append(generationCount)
            shown.sort()
            UserDefaults.standard.set(shown.map(String.init).joined(separator: ","), forKey: ratingModalShownKey)
        }
    }

    /// Сбросить майлстоуны показа запроса оценки (для debug / тестов).
    func resetRatingModalShownMilestones() {
        UserDefaults.standard.removeObject(forKey: ratingModalShownKey)
        UserDefaults.standard.removeObject(forKey: Self.userRatedAppPositiveKey)
    }

    /// Хранит выбранный эффект отдельно от enum route, чтобы Effect Detail мог восстановиться при SwiftUI re-render.
    func openEffectDetail(_ preset: EffectPreset, carouselPresets: [EffectPreset]? = nil, dismissTo: EffectDetailDismissDestination = .effectsHome) {
        let sequence = carouselPresets ?? [preset]
        selectedEffectPreset = preset
        effectDetailCarouselPresets = Self.uniquePresetsPreservingOrder(sequence)
        effectDetailDismissDestination = dismissTo
        currentScreen = .effectDetail
    }

    func dismissEffectDetail() {
        selectedEffectPreset = nil
        effectDetailCarouselPresets = []
        switch effectDetailDismissDestination {
        case .effectsHome:
            currentScreen = .effectsHome
        case .effectsBrowse(let section):
            currentScreen = .effectsSectionBrowse(section)
        }
    }

    /// Убираем дубликаты id, сохраняя порядок ленты — карусель не должна зацикливать один и тот же слайд.
    private static func uniquePresetsPreservingOrder(_ presets: [EffectPreset]) -> [EffectPreset] {
        var seen = Set<Int>()
        var result: [EffectPreset] = []
        result.reserveCapacity(presets.count)
        for p in presets where seen.insert(p.id).inserted {
            result.append(p)
        }
        return result
    }

    func openEffectsSectionBrowse(_ section: EffectsHomeSection) {
        currentScreen = .effectsSectionBrowse(section)
    }

    // Проверка лимитов генераций
    func presentPaywallFullscreen(placementTier: PaywallPlacementTier? = nil) {
        let resolvedTier = placementTier ?? (isProUser ? .proUpsell : .standard)
        adaptyService.setPaywallPlacementTier(resolvedTier)
        PaywallCacheManager.shared.setPlacementTier(resolvedTier)
        isPaywallOverlayPresented = true
    }

    func dismissPaywallOverlay() {
        isPaywallOverlayPresented = false
    }

    func checkGenerationLimit() -> Bool {
        if isProUser {
            checkAndResetProPeriodIfNeeded()
            guard let limit = proGenerationsLimit else {
                // Лимит неизвестен → не блокируем
                return true
            }
            let hasSubscriptionGenerations = proGenerationsUsed < limit
            let hasBonusGenerations = bonusGenerations > 0
            let allowed = hasSubscriptionGenerations || hasBonusGenerations
            print("🚦 [AppState] PRO limit: \(proGenerationsUsed)/\(limit), bonus: \(bonusGenerations) → \(allowed ? "allowed" : "blocked")")
            return allowed
        }
        
        // Не PRO, но есть оплаченные бонусные генерации (пакеты) → разрешаем тратить их.
        if bonusGenerations > 0 {
            print("🚦 [AppState] Bonus-only mode: bonus=\(bonusGenerations) → allowed")
            return true
        }
        
        let allowed = successfulGenerationsCount < freeGenerationsLimit
        print("🚦 [AppState] Free limit: \(successfulGenerationsCount)/\(freeGenerationsLimit) → \(allowed ? "allowed" : "blocked")")
        return allowed
    }

    // MARK: - PRO period management

    /// Только устанавливает момент начала периода если он ещё не задан (без сброса счётчика).
    /// Используется при восстановлении покупок, чтобы не обнулять накопленные траты.
    func initProPeriodIfNeeded() {
        guard isProUser, proGenerationsPeriodStart == 0 else { return }
        proGenerationsPeriodStart = Date().timeIntervalSince1970
        print("🔄 [AppState] PRO period start set on restore (count unchanged)")
    }

    /// Сбрасывает счётчик использованных генераций если текущий период закончился.
    func checkAndResetProPeriodIfNeeded() {
        guard isProUser else { return }

        // Первый вход в PRO (через покупку) — период уже инициализирован в onBecamePro.
        // Через restore — инициализируем start, но не трогаем счётчик.
        if proGenerationsPeriodStart == 0 {
            proGenerationsPeriodStart = Date().timeIntervalSince1970
            // Не сбрасываем proGenerationsUsed здесь: если дошли сюда через restore,
            // счётчик не должен обнуляться.
            print("🔄 [AppState] PRO period start initialized (preserve used count)")
            return
        }

        let periodStart = Date(timeIntervalSince1970: proGenerationsPeriodStart)
        let planId = adaptyService.currentSubscriptionProductId ?? ""
        let isWeekly = planId.contains("weekly") || planId.contains("week")
        let periodSeconds: TimeInterval = isWeekly ? 7 * 24 * 3600 : 365 * 24 * 3600

        if Date().timeIntervalSince(periodStart) >= periodSeconds {
            proGenerationsUsed = 0
            proGenerationsPeriodStart = Date().timeIntervalSince1970
            print("🔄 [AppState] PRO period reset (\(isWeekly ? "weekly" : "annual"))")
        }
    }

    /// Вызывается когда пользователь впервые оформляет подписку.
    func onBecamePro() {
        proGenerationsUsed = 0
        proGenerationsPeriodStart = Date().timeIntervalSince1970
        print("✅ [AppState] PRO tracking initialized")
    }

    /// Добавляет бонусные генерации из разового пакета.
    func addBonusGenerations(_ count: Int) {
        bonusGenerations += count
        tokenWallet.addTokens(count)
        print("🎁 [AppState] +\(count) bonus generations. Total bonus: \(bonusGenerations)")
    }

    func spendTokensForGeneration(cost: Int) -> Bool {
        tokenWallet.debit(cost)
    }

    func refundTokensForGeneration(cost: Int) {
        tokenWallet.refund(cost)
    }

    func presentInsufficientTokensGate(requiredTokens: Int) {
        tokenWallet.syncWithCurrentConfig()

        if isProUser {
            presentPaywallFullscreen(placementTier: .proUpsell)
            return
        }

        guard let modalManager = dynamicModalManager else {
            presentPaywallFullscreen(placementTier: .standard)
            return
        }

        let currentBalance = tokenWallet.balance
        let dailyCap = tokenWallet.dailyAllowance
        let description = tokensInsufficientModalDescription(
            currentBalance: currentBalance,
            requiredTokens: requiredTokens,
            dailyRefillCap: dailyCap
        )
        modalManager.showModal(with: DynamicModalConfig(
            title: "tokens_insufficient_title".localized,
            description: description,
            primaryButtonTitle: "tokens_insufficient_primary".localized,
            secondaryButtonTitle: "not_now".localized,
            iconName: "sparkles",
            primaryAction: { [weak self, weak modalManager] in
                modalManager?.dismissModal()
                self?.presentPaywallFullscreen(placementTier: .standard)
            },
            secondaryAction: { [weak modalManager] in
                modalManager?.dismissModal()
            },
            showsHeroDecoration: true
        ))
    }

    /// Если стоимость генерации выше дневного лимита пополнения из конфига, подсказку «завтра» не показываем — за день так всё равно не накопить.
    private func tokensInsufficientModalDescription(currentBalance: Int, requiredTokens: Int, dailyRefillCap: Int) -> String {
        let body = "tokens_insufficient_body".localized(with: currentBalance, requiredTokens)
        guard requiredTokens <= dailyRefillCap else { return body }
        let tomorrowHint = "tokens_insufficient_come_back_tomorrow".localized
        return "\(body) \(tomorrowHint)"
    }
    
    /// Диалог «нравится приложение» → системный запрос оценки или модалка негативного фидбека. Майлстоуны генераций и пункт «Оценить» в настройках.
    func presentAppRatingPrompt() {
        guard let modalManager = dynamicModalManager else { 
            return 
        }
        
        let config = DynamicModalConfig.appRating(
            primaryAction: {
                self.markUserRatedAppPositive()
                // Показываем нативный диалог оценки
                if #available(iOS 14.0, *) {
                    RateService().requestReview()
                } else {
                    RateService().rateApp()
                }
            },
            secondaryAction: {
                // Сначала закрываем текущую модалку
                modalManager.dismissModal()
                
                // Затем с задержкой показываем модальное окно для сбора отрицательного отзыва
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let feedbackConfig = DynamicModalConfig(
                        title: "feedback_sad_title".localized,
                        description: "feedback_sad_description".localized,
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
                        inputFieldType: .multiLine(placeholder: "feedback_placeholder".localized),
                        inputText: .constant(""),
                        inputAction: { message in
                            // Отправляем отзыв через ContactService
                            ContactService.shared.submitContactForm(message: "Negative feedback: \(message)") { result in
                                DispatchQueue.main.async {
                                    switch result {
                                    case .success:
                                        self.notificationManager.showSuccess("feedback_thank_you".localized)
                                        modalManager.dismissModal()
                                    case .failure(let error):
                                        self.notificationManager.showError("error_feedback_send_failed".localized(with: error.localizedDescription))
                                    }
                                }
                            }
                        },
                        inputValidationError: { errorMessage in
                            self.notificationManager.showError(errorMessage)
                        },
                        allowDismissOnBackgroundTap: true,
                        showsHeroDecoration: false
                    )
                    
                    modalManager.showModal(with: feedbackConfig)
                }
            }
        )
        modalManager.showModal(with: config)
    }
    
    func removeGeneratedMedia(withId id: String) {
        // Находим медиа для удаления
        if let mediaToDelete = generatedMedia.first(where: { $0.id == id }) {
            // Удаляем файл из локального хранилища
            GeneratedImageService.shared.deleteGeneratedImage(mediaToDelete)
        }
        
        // Удаляем из массива в памяти
        generatedMedia.removeAll { $0.id == id }
    }
    
    
    func toggleTestData() {
        generatedMedia.removeAll()
    }
    
    // MARK: - Error Handling
    
    /// Показывает ошибку через глобальный NotificationManager
    func showError(_ message: String) {
        print("🔔 [AppState] showError() called with message: '\(message)'")
        notificationManager.showError(message)
        print("🔔 [AppState] NotificationManager.showError() completed")
    }
    
    /// Показывает локализованную ошибку
    func showLocalizedError(_ key: String) {
        let localizedMessage = key.localized
        print("🔔 [AppState] showLocalizedError() called with key: '\(key)'")
        print("🔔 [AppState] Localized message: '\(localizedMessage)'")
        notificationManager.showError(localizedMessage)
        print("🔔 [AppState] NotificationManager.showError() completed for localized message")
    }
    
    /// Показывает ошибку сети
    func showNetworkError() {
        showLocalizedError("network_error")
    }
    
    /// Показывает ошибку загрузки фото
    func showPhotoUploadError() {
        showLocalizedError("photo_upload_error")
    }
    
    /// Показывает ошибку генерации
    func showGenerationError() {
        print("🔔 [AppState] showGenerationError() called")
        print("🔔 [AppState] Calling showLocalizedError with 'generation_failed'")
        showLocalizedError("generation_failed")
        print("🔔 [AppState] Error notification should be visible now")
    }
    
    /// Показывает ошибку с кастомным сообщением
    func showCustomError(_ message: String) {
        notificationManager.showError(message)
    }
    
    // MARK: - Language Management
    func setLanguage(_ language: String) {
        _appLanguage = language
        currentLanguage = language
        // Только `app_language`: наши строки берут его в `String.localized`. Не пишем `AppleLanguages` — иначе портится `Locale.preferredLanguages` и ломается логика «язык телефона» в настройках.
        UserDefaults.standard.set(language, forKey: "app_language")
        UserDefaults.standard.synchronize()
        
        objectWillChange.send()
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
        
        print("🌍 [AppState] Language changed to: \(language)")
    }
    
    func getCurrentLanguage() -> String {
        return currentLanguage
    }
    
    /// Эндоним языка (как в шите настроек), не перевод текущей локали UI.
    func getLanguageDisplayName(_ language: String) -> String {
        AppLanguageSupport.nativeEndonym(for: language)
    }
    
    private func initializeLanguage() {
        if UserDefaults.standard.object(forKey: "app_language") == nil {
            let initial: String
            if let phone = AppLanguageSupport.phoneLanguageCode(),
               phone != "en",
               AppLanguageSupport.bundledLanguageCodes.contains(phone) {
                initial = phone
            } else {
                initial = "en"
            }
            _appLanguage = initial
            currentLanguage = initial
            UserDefaults.standard.set(initial, forKey: "app_language")
            UserDefaults.standard.synchronize()
            print("🌍 [AppState] Language initialized to: \(currentLanguage) (phone: \(AppLanguageSupport.phoneLanguageCode() ?? "?"))")
        } else {
            currentLanguage = _appLanguage
            UserDefaults.standard.synchronize()
            print("🌍 [AppState] Language restored: \(currentLanguage)")
        }
    }
    
    
    // MARK: - Adapty Integration

    private func setupTokenWalletObservers() {
        PaywallCacheManager.shared.$paywallConfig
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                guard let self else { return }
                self.tokenWallet.syncWithCurrentConfig(config: config)
            }
            .store(in: &cancellables)
    }
    
    /// Настраивает наблюдатели для Adapty Service
    @MainActor
    private func setupAdaptyObservers() {
        // Подписываемся на изменения статуса PRO пользователя
        adaptyService.$isProUser
            .sink { [weak self] isPro in
                self?.isProUser = isPro
                
                // Закрываем оверлей paywall — пользователь остаётся на том экране, где был до покупки.
                if isPro && self?.isPaywallOverlayPresented == true {
                    DispatchQueue.main.async {
                        self?.dismissPaywallOverlay()
                        print("✅ [AppState] User became PRO — paywall overlay dismissed")
                    }
                }
            }
            .store(in: &cancellables)
        
        // Подписываемся на ошибки Adapty
        adaptyService.$error
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.notificationManager.showError("paywall_error_adapty_subscription".localized(with: error))
            }
            .store(in: &cancellables)
    }
    
    private func setupImageCacheObserver() {
        NotificationCenter.default.publisher(for: .imageCacheCleared)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                print("🗑️ [AppState] Image cache cleared")
            }
            .store(in: &cancellables)
    }
    
    /// Обновляет статус PRO пользователя из Adapty. Если включён дебаг и включён PRO через Debug — не перезаписываем статус ответом Adapty.
    @MainActor
    func updateProStatusFromAdapty() {
        if isDebugModeEnabled && UserDefaults.standard.bool(forKey: Self.debugProOverrideKey) {
            isProUser = true
            adaptyService.isProUser = true
            return
        }
        adaptyService.fetchProfile()
    }

    /// Ключ UserDefaults: PRO включён вручную в Debug-режиме (должен сохраняться между запусками).
    static let debugProOverrideKey = "debug_pro_override"
    
    /// Проверяет, есть ли активная подписка
    @MainActor
    func hasActiveSubscription() -> Bool {
        return adaptyService.hasActiveSubscription()
    }
    
    /// Получает информацию о подписке
    @MainActor
    func getSubscriptionInfo() -> (isActive: Bool, expiresAt: Date?, productId: String?) {
        return adaptyService.getSubscriptionInfo()
    }
    
    // MARK: - Debug Mode Management
    
    /// Включает дебаг режим
    func enableDebugMode() {
        isDebugModeEnabled = true
        print("🔧 [AppState] Debug mode enabled")
    }
    
    /// Выключает дебаг режим
    func disableDebugMode() {
        isDebugModeEnabled = false
        print("🔧 [AppState] Debug mode disabled")
    }
    
    /// Проверяет пароль дебаг режима
    func verifyDebugPassword(_ password: String) -> Bool {
        guard let expectedHash = ConfigurationManager.shared.getValue(for: .debugPasswordHash),
              !expectedHash.isEmpty else {
            print("❌ [AppState] DEBUG_PASSWORD_HASH missing or empty in APIKeys")
            return false
        }
        
        // Хеш в plist: SHA-512 в hex (строчные a–f); сырые байты для хеша — пароль и сразу за ним bundle id основного bundle приложения, без разделителя между ними (привязка к конкретному приложению).
        let salt = Bundle.main.bundleIdentifier ?? ""
        let inputHash = (password + salt).sha512()
        let isValid = inputHash == expectedHash
        
        print("🔧 [AppState] Password verification: \(isValid ? "SUCCESS" : "FAILED")")
        return isValid
    }
    
    /// Принудительно перезагружает данные приложения
    @MainActor
    func forceReloadData() {
        print("🔄 [AppState] Force reload...")
        loadInitialData()
    }
    
    // MARK: - Memory Management
    
    func handleMemoryWarning() {
        print("⚠️ [AppState] Memory warning received, clearing caches")
        ImageDownloader.shared.clearCache()
    }
    
    func handleAppDidBecomeActive() {
        print("🔄 [AppState] App became active, checking for data updates")
        // При возврате в приложение косметически обновляем период PRO-подписки,
        // чтобы лимит генераций и цифра на плашке сразу были актуальными.
        checkAndResetProPeriodIfNeeded()
        // Дальнейшее обновление состояния обрабатывается во вьюхах.
    }
    
    // MARK: - Helper Methods
    
}
