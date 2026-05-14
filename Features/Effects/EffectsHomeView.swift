import SwiftUI

struct EffectsHomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var paywallCache = PaywallCacheManager.shared
    // Чип токенов в шапке временно отключён — при возврате раскомментируй вместе с `ProStatusBadge` в `topBarActions`.
    // @ObservedObject private var tokenWallet = TokenWalletService.shared
    @State private var heroCarouselIndex = 0
    /// При >1 слайде: индекс страницы в расширенном `TabView` (`[last]+items+[first]`), как в `EffectDetailPresetCarousel`.
    @State private var heroLoopPageIndex = 1
    /// Мгновенный перескок с «технических» крайних страниц без анимации (шов кольца незаметен).
    @State private var heroCarouselIsJumping = false
    /// Сигнал от `MediaVideoPlayer`/`AnimatedRaster`: motion реально стартовал; отсчёт `duration_seconds` ведём только после этого.
    @State private var heroActiveMotionPlaybackReady = false
    /// После ручного свайпа TabView: автолисталка молчит 30 с с момента смены слайда (программные смены помечаем отдельно).
    @State private var heroCarouselLastUserInteractionAt: Date?
    @State private var heroCarouselSuppressNextUserInteractionMark = false
    private let railAutoplayLimit = 3
    @State private var railVisibleAutoplayQueueBySection: [String: [String]] = [:]

    private var payload: EffectsHomePayload? { appState.sessionEffectsHomePayload }
    private var homePreviewWarmupIdentity: String {
        guard let payload else { return "none" }
        let phase = scenePhase == .active ? "active" : "inactive"
        let heroVideo: String
        if let hero = payload.hero, hero.items.indices.contains(heroCarouselIndex) {
            heroVideo = hero.items[heroCarouselIndex].preset.previewVideoURL?.absoluteString ?? "nil"
        } else {
            heroVideo = "nil"
        }
        return [phase, heroVideo].joined(separator: "|")
    }

    private var homeTailWarmupIdentity: String {
        guard let payload else { return "none" }
        let sectionsKey = payload.sections
            .map { section in
                let videos = section.items.compactMap { $0.preset.previewVideoURL?.absoluteString }.joined(separator: ",")
                let posters = section.items.compactMap { $0.preset.previewImageURL?.absoluteString }.joined(separator: ",")
                return "\(section.id)|v:\(videos)|p:\(posters)"
            }
            .joined(separator: ";")
        return "home-tail|\(sectionsKey)"
    }

    private var homeHeroSessionID: String {
        guard let hero = payload?.hero else { return "none" }
        return "home-hero|\(hero.sectionId)|\(heroCarouselIndex)"
    }

    /// Рельсы и «View all»: motion в карточках каталога; по умолчанию выключено в `logic`, Adapty может включить.
    private var effectsCatalogAllowsMotionPreview: Bool {
        paywallCache.paywallConfig?.logic.effectsCatalogAllowsMotionPreview ?? false
    }
    
    /// Каталог Effects (main + view all): показывать ли постер до старта motion. Работает только при включённом `effectsCatalogAllowsMotionPreview`.
    private var effectsCatalogShowPosterBeforeMotion: Bool {
        paywallCache.paywallConfig?.logic.effectsCatalogShowPosterBeforeMotion ?? false
    }

    /// Данные каталога приходят с сплеша (`ensureSessionRemoteDataAtLaunch`); на этом экране только читаем кэш `AppState`.
    private var showsBootstrapLoading: Bool {
        switch appState.sessionRemoteBootstrapPhase {
        case .idle, .loading:
            return appState.sessionEffectsHomePayload == nil
        case .ready, .failed:
            return false
        }
    }

    private var bootstrapErrorMessage: String? {
        if case .failed(let msg) = appState.sessionRemoteBootstrapPhase { return msg }
        return nil
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TopNavigationBar(
                    title: "effects_tab".localized,
                    showBackButton: false,
                    customRightContent: AnyView(topBarActions),
                    backgroundColor: AppTheme.Colors.background
                )

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                    }
                    // Без интерполяции: снятие .redacted и смена скелетон→контент иначе даёт «дрожащий» layout на первом кадре.
                    .contentTransition(.identity)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 110)
                }
            }
            .overlay(alignment: .bottom) {
                BottomNavigationBar()
            }
            .background(AppTheme.Colors.background.ignoresSafeArea())
            .themeAware()
            .themeAnimation()
        }
        .task(id: homePreviewWarmupIdentity) {
            await prewarmVisibleHomePreviewVideosIfNeeded()
        }
        .task(id: homeTailWarmupIdentity) {
            guard let payload else { return }
            await EffectsMediaOrchestrator.shared.reevaluateCatalogTailWarmupForHome(payload: payload)
        }
    }

    private var topBarActions: some View {
        HStack(spacing: 12) {
            Button {
                appState.currentScreen = .settings
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textPrimary)
            }
            .appPlainButtonStyle()
            .accessibilityLabel(Text("settings".localized))

            // ProStatusBadge(
            //     tokenBalance: tokenWallet.balance,
            //     action: {
            //         appState.presentPaywallFullscreen()
            //     }
            // )
        }
    }

    @ViewBuilder
    private var content: some View {
        if showsBootstrapLoading {
            loadingContent
        } else if let errorMessage = bootstrapErrorMessage {
            errorContent(message: errorMessage)
        } else if let payload, heroHasVisibleItems(payload.hero) || !payload.sections.isEmpty {
            if let hero = payload.hero, heroHasVisibleItems(hero) {
                heroCarousel(hero)
            }

            ForEach(payload.sections) { section in
                sectionView(section)
            }
        } else {
            emptyContent
        }
    }

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(AppTheme.Colors.cardBackground.opacity(0.75))
                .aspectRatio(16.0 / 9.0, contentMode: .fit)

            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(AppTheme.Colors.cardBackground.opacity(0.75))
                            .frame(width: 142, height: 190)
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    private func heroHasVisibleItems(_ hero: EffectsHeroCarousel?) -> Bool {
        guard let hero else { return false }
        return !hero.items.isEmpty
    }

    // Hero: карусель пресетов; при >1 слайде — кольцо через расширенный `TabView`, как на `EffectDetailView` (`EffectDetailPresetCarousel`).
    private func heroCarousel(_ hero: EffectsHeroCarousel) -> some View {
        let ratio = CGFloat(hero.layoutAspectWidthOverHeight)
        let n = hero.items.count
        let useLooping = n > 1

        return Group {
            if useLooping {
                let extended = [hero.items.last!] + hero.items + [hero.items.first!]
                TabView(selection: $heroLoopPageIndex) {
                    ForEach(Array(extended.enumerated()), id: \.offset) { offset, item in
                        let realIndex = heroExtendedOffsetToRealIndex(offset, itemCount: n)
                        heroSlide(hero: hero, item: item, index: realIndex)
                            .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .transaction { txn in
                    if heroCarouselIsJumping { txn.disablesAnimations = true }
                }
                .onChange(of: heroLoopPageIndex) { oldValue, newValue in
                    // После «шва» кольца (дубликат первого → страница 1) тот же пресет: повторный сброс motion даёт рывок плеера/постера.
                    let oldReal = heroExtendedOffsetToRealIndex(oldValue, itemCount: n)
                    let newReal = heroExtendedOffsetToRealIndex(newValue, itemCount: n)
                    if oldReal != newReal {
                        heroActiveMotionPlaybackReady = false
                    }
                    if heroCarouselSuppressNextUserInteractionMark {
                        heroCarouselSuppressNextUserInteractionMark = false
                    } else if !heroCarouselIsJumping {
                        heroCarouselLastUserInteractionAt = Date()
                    }
                    commitHeroLoopPage(newValue, itemCount: n)
                }
            } else {
                TabView(selection: $heroCarouselIndex) {
                    ForEach(Array(hero.items.enumerated()), id: \.element.id) { index, item in
                        heroSlide(hero: hero, item: item, index: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: heroCarouselIndex) { _, _ in
                    heroActiveMotionPlaybackReady = false
                    if heroCarouselSuppressNextUserInteractionMark {
                        heroCarouselSuppressNextUserInteractionMark = false
                    } else {
                        heroCarouselLastUserInteractionAt = Date()
                    }
                }
            }
        }
        .id(hero.sectionId)
        .aspectRatio(ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .task(id: heroAutoplayTaskIdentity(hero)) {
            await runHeroAutoplayLoop(hero: hero)
        }
        .onChange(of: hero.sectionId) { _, _ in
            heroCarouselSuppressNextUserInteractionMark = true
            heroCarouselLastUserInteractionAt = nil
            heroCarouselIndex = 0
            heroLoopPageIndex = 1
        }
        .onChange(of: hero.items.count) { _, newCount in
            guard newCount > 0 else { return }
            heroCarouselSuppressNextUserInteractionMark = true
            heroCarouselIndex %= newCount
            if newCount > 1 {
                heroCarouselIsJumping = true
                heroLoopPageIndex = heroCarouselIndex + 1
                DispatchQueue.main.async {
                    heroCarouselIsJumping = false
                }
            }
        }
    }

    private func heroExtendedOffsetToRealIndex(_ offset: Int, itemCount n: Int) -> Int {
        if offset == 0 { return n - 1 }
        if offset == n + 1 { return 0 }
        return offset - 1
    }

    private func commitHeroLoopPage(_ newValue: Int, itemCount n: Int) {
        guard n > 1 else { return }
        let lastExtended = n + 1

        if newValue == 0 {
            heroCarouselIndex = n - 1
            jumpHeroLoopPage(to: n)
            return
        }
        if newValue == lastExtended {
            heroCarouselIndex = 0
            jumpHeroLoopPage(to: 1)
            return
        }
        heroCarouselIndex = newValue - 1
    }

    private func jumpHeroLoopPage(to target: Int) {
        DispatchQueue.main.async {
            heroCarouselSuppressNextUserInteractionMark = true
            heroCarouselIsJumping = true
            heroLoopPageIndex = target
            DispatchQueue.main.async {
                heroCarouselIsJumping = false
            }
        }
    }

    /// Ключ `.task`: смена состава hero, URL motion у пресета, индекс или фаза сцены перезапускают цикл автолисталки.
    private func heroAutoplayTaskIdentity(_ hero: EffectsHeroCarousel) -> String {
        let phase = scenePhase == .active ? "active" : "inactive"
        let itemsKey = hero.items
            .map { "\($0.preset.id)|\($0.preset.previewVideoURL?.absoluteString ?? "nil")" }
            .joined(separator: ";")
        return "\(hero.sectionId)|\(itemsKey)|\(heroCarouselIndex)|\(phase)"
    }

    /// Пауза на слайде после старта motion: `duration_seconds` из RPC; при `nil`/0 — 10 с; clamp 2…120 с.
    private func heroAutopauseSeconds(for item: EffectsHomeItem) -> Double {
        guard let raw = item.preset.durationSeconds, raw > 0 else { return 10 }
        return min(max(Double(raw), 2), 120)
    }

    /// Автолисталка: ждём старт motion, затем `duration_seconds`; только постер (без URL motion) не листаем, пока не придёт URL; после ручного свайпа — 30 с «тишины».
    @MainActor
    private func runHeroAutoplayLoop(hero: EffectsHeroCarousel) async {
        guard hero.items.count > 1 else { return }
        while !Task.isCancelled {
            guard scenePhase == .active else {
                try? await Task.sleep(nanoseconds: 400_000_000)
                continue
            }
            if let lastTouch = heroCarouselLastUserInteractionAt {
                let since = Date().timeIntervalSince(lastTouch)
                if since < 30 {
                    let remaining = 30 - since
                    let chunk = min(remaining, 0.25)
                    let ns = UInt64(chunk * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: max(1, ns))
                    continue
                }
            }

            let idx = heroCarouselIndex
            guard hero.items.indices.contains(idx) else { break }
            let item = hero.items[idx]

            guard item.preset.previewVideoURL != nil else {
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }

            heroActiveMotionPlaybackReady = false
            let motionWaitDeadline = ContinuousClock.now + .seconds(45)
            while !Task.isCancelled {
                let (ready, curIdx, phase) = (heroActiveMotionPlaybackReady, heroCarouselIndex, scenePhase)
                if phase != .active { break }
                if curIdx != idx { break }
                if ready { break }
                if ContinuousClock.now >= motionWaitDeadline { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled, scenePhase == .active, heroCarouselIndex == idx else { continue }

            if let lastTouch = heroCarouselLastUserInteractionAt, Date().timeIntervalSince(lastTouch) < 30 {
                continue
            }

            let pauseSec = heroAutopauseSeconds(for: item)
            let pauseEndDate = Date().addingTimeInterval(pauseSec)
            while !Task.isCancelled && Date() < pauseEndDate {
                guard scenePhase == .active, heroCarouselIndex == idx else { break }
                if let lastTouch = heroCarouselLastUserInteractionAt, Date().timeIntervalSince(lastTouch) < 30 {
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled, scenePhase == .active, heroCarouselIndex == idx else { continue }
            if let lastTouch = heroCarouselLastUserInteractionAt, Date().timeIntervalSince(lastTouch) < 30 {
                continue
            }

            let n = hero.items.count
            heroCarouselSuppressNextUserInteractionMark = true
            // Кольцо: с последнего реального слайда уезжаем на дубликат первого (`n+1`), `commitHeroLoopPage` перескочит на страницу `1` без шва.
            if n > 1 {
                if idx == n - 1 {
                    heroLoopPageIndex = n + 1
                } else {
                    heroLoopPageIndex = idx + 2
                }
            } else {
                heroCarouselIndex = (idx + 1) % max(n, 1)
            }
        }
    }

    private func heroSlide(hero: EffectsHeroCarousel, item: EffectsHomeItem, index: Int) -> some View {
        Button {
            appState.openEffectDetail(item.preset, carouselPresets: hero.items.map(\.preset))
        } label: {
            // Градиент и типографика привязаны к слоту слайда, а не к внутреннему размеру превью (как в `EffectCatalogRailCard.catalogTile`).
            let playHeroMotion = index == heroCarouselIndex && scenePhase == .active
            ZStack(alignment: .bottom) {
                PreviewMediaView(
                    imageURL: item.preset.previewImageURL,
                    image: item.preset.bundledPreviewUIImage(),
                    motionURL: item.preset.previewVideoURL?.absoluteString,
                    shouldPlayMotion: playHeroMotion,
                    showsLoadingIndicator: false,
                    prefersMotionWhenCached: false,
                    // Hero не читает `effects_catalog_show_poster_before_motion`, но при тёплом motion-кэше не мигаем jpeg до первого кадра (как матрица `P=false, C=true` в EFFECTS_PREVIEW_BEHAVIOR_SPEC).
                    // showsPosterBeforeMotion: false,
                    debugLogTag: nil,
                    debugContext: "home-hero id=\(item.preset.id) slug=\(item.preset.slug) title='\(item.preset.title)' index=\(index)",
                    posterNetworkRequestTimeout: ImageDownloader.effectPreviewPosterNetworkRequestTimeoutSeconds,
                    onMotionPlaybackReady: (playHeroMotion && item.preset.previewVideoURL != nil)
                        ? { heroActiveMotionPlaybackReady = true }
                        : nil
                ) {
                    AppTheme.Colors.cardBackground
                }
                // См. рельсы: тот же `preset.id` + новые URL из RPC — сбрасываем `@State` превью, иначе hero может кратковременно держать старый кадр/плеер.
                .id(catalogRailCellIdentity(item))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                ZStack(alignment: .bottom) {
                    heroGradient
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Как в макете: название эффекта по центру над pill-кнопкой «Try Now»; тап по карточке открывает деталь.
                    VStack(spacing: 12) {
                        Text(item.preset.title)
                            .font(AppTheme.Typography.headline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 2)

                        Text("effects_hero_try_now".localized)
                            .font(AppTheme.Typography.buttonSmall)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(.white, in: Capsule())

                        if hero.items.count > 1 {
                            heroCarouselPageDots(count: hero.items.count, selectedIndex: heroCarouselIndex)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 22)
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .appPlainButtonStyle()
    }

    private var heroGradient: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.05),
                Color.black.opacity(0.45)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func heroCarouselPageDots(count: Int, selectedIndex: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                let on = i == selectedIndex
                Circle()
                    .fill(on ? Color.white : Color.white.opacity(0.38))
                    .frame(width: on ? 7 : 5, height: on ? 7 : 5)
                    .animation(.easeInOut(duration: 0.2), value: selectedIndex)
            }
        }
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    private func sectionView(_ section: EffectsHomeSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(section.title)
                    .font(AppTheme.Typography.subtitle)
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Spacer()

                Button {
                    appState.openEffectsSectionBrowse(section)
                } label: {
                    Text("view_all".localized)
                        .font(AppTheme.Typography.caption)
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .appPlainButtonStyle()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    // Ограничиваем autoplay по фактически видимым карточкам в каждом рельсе:
                    // новые видимые карточки вытесняют старые из лимита, даже если SwiftUI ещё не прислал `onDisappear`.
                    // `Identifiable` по `preset.id`, плюс `.id(urls…)`: иначе при смене только preview URL в RPC SwiftUI переиспользует ячейку и тянет старый `@State` плеера/постера.
                    ForEach(section.items) { item in
                        let autoplayKey = "\(item.id)"
                        EffectCatalogRailCard(
                            item: item,
                            layout: .railFixed142x190,
                            allowsMotionPreview: effectsCatalogAllowsMotionPreview,
                            showsPosterBeforeMotion: effectsCatalogShowPosterBeforeMotion,
                            autoplayEnabled: effectsCatalogAllowsMotionPreview && isRailAutoplayEnabled(
                                sectionId: section.id,
                                key: autoplayKey
                            ),
                            onVisibilityChanged: { isVisible in
                                updateRailAutoplayVisibility(
                                    sectionId: section.id,
                                    key: autoplayKey,
                                    isVisible: isVisible
                                )
                                if isVisible {
                                    scheduleCatalogPriorityUpdate(previewVideoURL: item.preset.previewVideoURL)
                                }
                            }
                        ) {
                            appState.openEffectDetail(item.preset, carouselPresets: section.items.map(\.preset))
                        }
                        .id(catalogRailCellIdentity(item))
                    }
                }
            }
        }
    }

    private func catalogRailCellIdentity(_ item: EffectsHomeItem) -> String {
        let v = item.preset.previewVideoURL?.absoluteString ?? ""
        let p = item.preset.previewImageURL?.absoluteString ?? ""
        return "\(item.id)|\(v)|\(p)"
    }

    private func isRailAutoplayEnabled(sectionId: String, key: String) -> Bool {
        railVisibleAutoplayQueueBySection[sectionId]?.contains(key) ?? false
    }

    private func updateRailAutoplayVisibility(sectionId: String, key: String, isVisible: Bool) {
        var queue = railVisibleAutoplayQueueBySection[sectionId] ?? []
        queue.removeAll { $0 == key }
        if isVisible {
            queue.append(key)
            if queue.count > railAutoplayLimit {
                queue = Array(queue.suffix(railAutoplayLimit))
            }
        }
        railVisibleAutoplayQueueBySection[sectionId] = queue
    }

    private func scheduleCatalogPriorityUpdate(previewVideoURL: URL?) {
        Task {
            await EffectsMediaOrchestrator.shared.scheduleCatalogCurrentPresetPriority(
                previewVideoURL: previewVideoURL
            )
        }
    }

    /// Прогрев превью на главной: hero всегда; рельсы с motion при `logic.effectsCatalogAllowsMotionPreview` подгружаются по мере показа.
    @MainActor
    private func prewarmVisibleHomePreviewVideosIfNeeded() async {
        guard let payload else { return }
        var heroURLString: String?
        if let hero = payload.hero, hero.items.indices.contains(heroCarouselIndex),
           let heroURL = hero.items[heroCarouselIndex].preset.previewVideoURL?.absoluteString {
            heroURLString = heroURL
        }
        await EffectsMediaOrchestrator.shared.updateHomeHeroSession(
            sceneIsActive: scenePhase == .active,
            heroSessionID: homeHeroSessionID,
            heroVideoURLString: heroURLString
        )
    }

    private func errorContent(message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(AppTheme.Typography.body)
                .foregroundColor(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await appState.retrySessionRemoteBootstrap() }
            } label: {
                Text("retry".localized)
                    .font(AppTheme.Typography.buttonSmall)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(AppTheme.Colors.cardBackground, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var emptyContent: some View {
        VStack(spacing: 12) {
            Text("effects_empty_title".localized)
                .font(AppTheme.Typography.title)
                .foregroundColor(AppTheme.Colors.textPrimary)

            Text("effects_empty_subtitle".localized)
                .font(AppTheme.Typography.body)
                .foregroundColor(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

}
