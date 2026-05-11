import PhotosUI
import SwiftUI
import UIKit

struct EffectDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var tokenWallet = TokenWalletService.shared
    @ObservedObject private var generationJob = GenerationJobService.shared

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false

    private var preset: EffectPreset? {
        appState.selectedEffectPreset
    }

    /// Фото подтягивается из `AppState`, чтобы не терялось при смене корневого экрана (таб «Галерея», «Создать», настройки и т.д.).
    private var selectedPhotoImage: UIImage? {
        appState.effectDetailDraftPhoto
    }

    /// Цепочка слайдов на detail совпадает с порядком секции / ленты (см. `AppState.effectDetailCarouselPresets`).
    private var carouselPresets: [EffectPreset] {
        appState.effectDetailCarouselPresets
    }

    private var showEffectCarousel: Bool {
        carouselPresets.count > 1
    }

    private var carouselIdentity: String {
        carouselPresets.map { String($0.id) }.joined(separator: "|")
    }

    private var detailPreviewWarmupIdentity: String {
        let phase = scenePhase == .active ? "active" : "inactive"
        let selectedId = preset.map { String($0.id) } ?? "nil"
        let selectedURL = preset?.previewVideoURL?.absoluteString ?? "nil"
        return [phase, selectedId, selectedURL, carouselIdentity].joined(separator: "|")
    }

    private var detailSessionID: String {
        let selectedId = preset.map { String($0.id) } ?? "nil"
        return "effect-detail|\(selectedId)|\(carouselIdentity)"
    }

    private var cost: Int {
        GenerationCostCalculator().effectGenerationCost(presetTokenCost: preset?.tokenCost)
    }

    /// Рамка миниатюры: clamp 9:16…16:9 + `scaledToFill`. Эталонный квадрат — 74×1.5 pt по стороне; остальные пропорции от него же, сверху множитель 1…1.5 от «расстояния» до 1:1 (как раньше, но от укрупнённого квадрата).
    private let userReferenceThumbSquareLongSide: CGFloat = 74 * 1.5
    private let userReferenceThumbAspectMin: CGFloat = 9.0 / 16.0
    private let userReferenceThumbAspectMax: CGFloat = 16.0 / 9.0

    private func clampedUserReferenceAspectWidthOverHeight(for image: UIImage) -> CGFloat {
        let w = max(image.size.width, 1)
        let h = max(image.size.height, 1)
        return min(max(w / h, userReferenceThumbAspectMin), userReferenceThumbAspectMax)
    }

    /// От 1.0 у квадрата до 1.5 у крайних 9:16 / 16:9 (на уже посчитанный `base` от `userReferenceThumbSquareLongSide`).
    private func userReferenceThumbnailScale(forClampedAspect ar: CGFloat) -> CGFloat {
        let minAR = userReferenceThumbAspectMin
        let maxAR = userReferenceThumbAspectMax
        let t: CGFloat
        if ar <= 1 {
            let denom = 1 - minAR
            guard denom > 1e-6 else { return 1 }
            t = (1 - ar) / denom
        } else {
            let denom = maxAR - 1
            guard denom > 1e-6 else { return 1 }
            t = (ar - 1) / denom
        }
        return 1 + 0.5 * min(max(t, 0), 1)
    }

    private func userReferenceThumbnailSize(for image: UIImage) -> CGSize {
        let ar = clampedUserReferenceAspectWidthOverHeight(for: image)
        let L = userReferenceThumbSquareLongSide
        let base: CGSize
        if ar >= 1 {
            base = CGSize(width: L, height: L / ar)
        } else {
            base = CGSize(width: L * ar, height: L)
        }
        let scale = userReferenceThumbnailScale(forClampedAspect: ar)
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    private func userReferenceThumbnailCornerRadius(for size: CGSize) -> CGFloat {
        min(16, min(size.width, size.height) * 0.24)
    }

    var body: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()

            if let preset {
                VStack(spacing: 0) {
                    TopNavigationBar(
                        title: preset.title,
                        showBackButton: true,
                        customRightContent: AnyView(
                            ProStatusBadge(
                                tokenBalance: tokenWallet.balance,
                                action: { appState.presentPaywallFullscreen() }
                            )
                        ),
                        backgroundColor: AppTheme.Colors.background,
                        onBackTap: {
                            Task { await appState.dismissEffectDetail() }
                        }
                    )

                    // Превью на всю область между навбаром и CTA (с отступами): раньше слот считался через `aspectRatio(.fit)` и центрировался — при широком аспекте пресета оставались большие поля сверху/снизу. `PreviewMediaView` сам режет `scaledToFill`.
                    GeometryReader { geo in
                        let padH: CGFloat = 16
                        let padV: CGFloat = 8
                        let availW = max(0, geo.size.width - padH * 2)
                        let availH = max(0, geo.size.height - padV * 2)

                        Group {
                            if showEffectCarousel {
                                EffectDetailPresetCarousel(
                                    presets: carouselPresets,
                                    selectionId: preset.id,
                                    card: { p, isCurrentPage, shouldPreloadMotion in
                                        previewCard(
                                            preset: p,
                                            allowVideoPlayback: isCurrentPage,
                                            preloadMotionWhenHidden: shouldPreloadMotion
                                        )
                                    },
                                    onCommit: { newPreset in
                                        if appState.selectedEffectPreset?.id != newPreset.id {
                                            appState.selectedEffectPreset = newPreset
                                        }
                                    }
                                )
                                .id(carouselIdentity)
                            } else {
                                previewCard(
                                    preset: preset,
                                    allowVideoPlayback: true,
                                    preloadMotionWhenHidden: false
                                )
                            }
                        }
                        .frame(width: availW, height: availH)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomActionBar
                }
            } else {
                missingEffectState
            }
        }
        .themeAware()
        .themeAnimation()
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadSelectedPhoto(newItem) }
        }
        .task(id: detailPreviewWarmupIdentity) {
            await prewarmDetailPreviewVideosIfNeeded()
        }
    }

    private func previewCard(
        preset: EffectPreset,
        allowVideoPlayback: Bool,
        preloadMotionWhenHidden: Bool
    ) -> some View {
        // Если detail перекрыт fullscreen-оверлеем (например paywall), считаем экран неактивным:
        // не держим autoplay/звук под верхним слоем, а после закрытия оверлея поведение восстанавливается.
        let isDetailScreenInteractable = scenePhase == .active && !appState.isPaywallOverlayPresented
        return GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)

                // Общий медиа-слой эффекта используется и в карточках, и на detail: постер + motion поверх с поддержкой WebP.
                PreviewMediaView(
                    imageURL: preset.previewImageURL,
                    image: preset.bundledPreviewUIImage(),
                    motionURL: preset.previewVideoURL?.absoluteString,
                    shouldPlayMotion: isDetailScreenInteractable && allowVideoPlayback,
                    preloadsMotionWhenHidden: isDetailScreenInteractable && !allowVideoPlayback && preloadMotionWhenHidden,
                    showsLoadingIndicator: false,
                    // Если AV-motion уже в дисковом кэше, не показываем промежуточный постер: убираем визуальный «скачок» при листании detail.
                    prefersMotionWhenCached: true,
                    // На detail оставляем политику «loader -> video» для кэшированного AV независимо от каталожного флага.
                    showsPosterBeforeMotion: false,
                    motionPlaybackVolumeOverride: isDetailScreenInteractable ? 0.07 : 0.0,
                    debugLogTag: nil,
                    debugContext: "detail id=\(preset.id) slug=\(preset.slug) title='\(preset.title)'"
                ) {
                    if preset.previewImageURL != nil {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "safari")
                                .font(.system(size: 36, weight: .regular))
                                .foregroundColor(AppTheme.Colors.textSecondary)
                            Text("effect_detail_vertical_preview".localized)
                                .font(AppTheme.Typography.caption)
                                .foregroundColor(AppTheme.Colors.textSecondary)
                        }
                    }
                }
                .frame(width: w, height: h)
            }
            .frame(width: w, height: h)
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .overlay(alignment: .bottomTrailing) {
            if let selectedPhotoImage {
                selectedPhotoOverlay(selectedPhotoImage)
                    .padding(14)
            }
        }
    }

    private func selectedPhotoOverlay(_ image: UIImage) -> some View {
        let thumbSize = userReferenceThumbnailSize(for: image)
        let thumbRadius = userReferenceThumbnailCornerRadius(for: thumbSize)
        // Корзина у миниатюры: inset от угла + offset чуть вниз и влево от прежней позиции.
        return ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: thumbSize.width, height: thumbSize.height)
                .clipShape(RoundedRectangle(cornerRadius: thumbRadius, style: .continuous))
                .compositingGroup()
                .shadow(color: Color.black.opacity(0.62), radius: 10, x: 0, y: 5)
                .shadow(color: Color.black.opacity(0.42), radius: 18, x: 0, y: 10)

            Button {
                appState.clearEffectDetailDraftPhoto()
                selectedPhotoItem = nil
            } label: {
                IconView("Delete", size: 13, color: AppTheme.Colors.onPrimaryText.opacity(0.75))
                    .padding(4)
                    .background(Color.black.opacity(0.75), in: Circle())
            }
            .appPlainButtonStyle()
            .padding(.top, 2)
            .padding(.trailing, 2)
            .offset(x: -2, y: 2)
        }
    }

    /// Нижняя панель: заголовок эффекта уже в навбаре, под кнопкой подписей не показываем.
    private var bottomActionBar: some View {
        let uploadTitle = isLoadingPhoto ? "loading".localized : "effect_detail_upload_photo".localized
        return VStack(spacing: 0) {
            if selectedPhotoImage == nil {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    PrimaryGenerationButtonLabel(
                        title: uploadTitle,
                        isEnabled: !isLoadingPhoto
                    )
                }
                .appPlainButtonStyle()
                .disabled(isLoadingPhoto)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            } else {
                Button {
                    handleGenerateTap()
                } label: {
                    PrimaryGenerationButtonLabel(
                        title: "generate".localized,
                        tokenCost: cost,
                        isEnabled: !generationJob.isRunning
                    )
                }
                .appPlainButtonStyle()
                .disabled(generationJob.isRunning)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            AppTheme.Colors.background
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var missingEffectState: some View {
        VStack(spacing: 16) {
            Text("effect_detail_missing_title".localized)
                .font(AppTheme.Typography.title)
                .foregroundColor(AppTheme.Colors.textPrimary)

            Button {
                Task { await appState.dismissEffectDetail() }
            } label: {
                Text("back_to_effects".localized)
                    .font(AppTheme.Typography.button)
                    .foregroundColor(AppTheme.Colors.onPrimaryText)
                    .primaryCTAChrome(isEnabled: true, fill: .productGradient)
            }
            .appPlainButtonStyle()
        }
        .padding(16)
    }

    @MainActor
    private func loadSelectedPhoto(_ item: PhotosPickerItem) async {
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }

        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage.decodedForAPIUpload(from: data) {
                appState.setEffectDetailDraftPhoto(image)
            }
        } catch {
            appState.notificationManager.showError(error.localizedDescription)
        }
    }

    private func handleGenerateTap() {
        guard let preset, let selectedPhotoImage else { return }
        do {
            let inputImagePath = try generationJob.persistInputImage(selectedPhotoImage)
            generationJob.start(request: .effect(preset: preset, inputImagePath: inputImagePath), cost: cost)
        } catch {
            appState.notificationManager.showError(error.localizedDescription)
        }
    }

    /// На detail прогреваем текущий пресет и ближайших соседей карусели, чтобы свайп по пресетам переключался без «холодного» старта видео.
    @MainActor
    private func prewarmDetailPreviewVideosIfNeeded() async {
        await EffectsMediaOrchestrator.shared.updateDetailSession(
            sceneIsActive: scenePhase == .active,
            detailSessionID: detailSessionID,
            selectedPreset: preset,
            carouselPresets: carouselPresets
        )
    }
}

// MARK: - Зацикленная горизонтальная карусель пресетов

/// Кольцо через `TabView(.page)`: SwiftUI сам держит свайп/размер страницы, а мы только
/// перескакиваем с технических `[last]` / `[first]` слайдов на реальные элементы без видимого шва.
private struct EffectDetailPresetCarousel<Card: View>: View {
    let presets: [EffectPreset]
    let selectionId: Int
    /// Аргументы card:
    /// 1) preset, 2) это активная страница (играем video), 3) соседняя страница (держим player прогретым в paused).
    @ViewBuilder let card: (EffectPreset, Bool, Bool) -> Card
    let onCommit: (EffectPreset) -> Void

    @State private var pageIndex: Int
    @State private var isJumping = false

    /// Расстояние между соседними карточками при свайпе: у `TabView(.page)` каждая страница на всю ширину, поэтому даём симметричный горизонтальный inset. (Не `static`: в generic-типах запрещены static stored properties.)
    private let interCardGap: CGFloat = 14

    private var useLooping: Bool { presets.count > 1 }

    private var extended: [EffectPreset] {
        guard useLooping else { return presets }
        return [presets.last!] + presets + [presets.first!]
    }

    init(
        presets: [EffectPreset],
        selectionId: Int,
        @ViewBuilder card: @escaping (EffectPreset, Bool, Bool) -> Card,
        onCommit: @escaping (EffectPreset) -> Void
    ) {
        self.presets = presets
        self.selectionId = selectionId
        self.card = card
        self.onCommit = onCommit
        let idx = presets.firstIndex { $0.id == selectionId } ?? 0
        _pageIndex = State(initialValue: presets.count > 1 ? idx + 1 : idx)
    }

    var body: some View {
        TabView(selection: $pageIndex) {
            ForEach(Array(extended.enumerated()), id: \.offset) { idx, preset in
                card(preset, idx == pageIndex, shouldPreloadMotion(forExtendedIndex: idx))
                    .padding(.horizontal, interCardGap / 2)
                    .clipped()
                    .contentShape(Rectangle())
                    .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .transaction { transaction in
            if isJumping {
                transaction.disablesAnimations = true
            }
        }
        .onAppear {
            syncFromSelection(animated: false)
        }
        .onChange(of: selectionId) { _, _ in
            syncFromSelection(animated: false)
        }
        .onChange(of: pageIndex) { _, newValue in
            commitVisiblePage(newValue)
        }
    }

    /// Прогреваем только ближайшие к активной странице карточки — это даёт мгновенный старт после свайпа и не раздувает число поднятых AVPlayer.
    private func shouldPreloadMotion(forExtendedIndex idx: Int) -> Bool {
        guard useLooping else { return false }
        return abs(idx - pageIndex) == 1
    }

    private func syncFromSelection(animated: Bool) {
        let idx = presets.firstIndex { $0.id == selectionId } ?? 0
        let target = useLooping ? idx + 1 : idx
        guard pageIndex != target else { return }

        if animated {
            pageIndex = target
        } else {
            isJumping = true
            pageIndex = target
            DispatchQueue.main.async {
                isJumping = false
            }
        }
    }

    private func commitVisiblePage(_ newValue: Int) {
        guard useLooping else {
            guard presets.indices.contains(newValue) else { return }
            onCommit(presets[newValue])
            return
        }

        if newValue == 0 {
            let lastRealIndex = presets.count - 1
            onCommit(presets[lastRealIndex])
            jump(to: presets.count)
            return
        }

        if newValue == extended.count - 1 {
            onCommit(presets[0])
            jump(to: 1)
            return
        }

        let realIndex = newValue - 1
        guard presets.indices.contains(realIndex) else { return }
        onCommit(presets[realIndex])
    }

    private func jump(to target: Int) {
        DispatchQueue.main.async {
            isJumping = true
            pageIndex = target
            DispatchQueue.main.async {
                isJumping = false
            }
        }
    }
}
