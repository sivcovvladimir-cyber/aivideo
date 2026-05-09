import SwiftUI
import ImageIO

// Статический кэш превью-карточек галереи. Живёт вне @State,
// поэтому картинки не перезагружаются при переключении вкладок.
enum GalleryThumbnailCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()

    /// Подпись последнего прогрева (чтобы не гонять декод повторно при втором loadGeneratedMedia с тем же составом).
    private static var lastWarmupSignature: String?
    private static let warmupLock = NSLock()

    static func get(_ id: String) -> UIImage? {
        cache.object(forKey: NSString(string: id))
    }

    static func set(_ id: String, image: UIImage) {
        cache.setObject(image, forKey: NSString(string: id))
    }

    static func clear() {
        cache.removeAllObjects()
        warmupLock.lock()
        lastWarmupSignature = nil
        warmupLock.unlock()
    }

    /// Прогрев первой страницы: чтение и декод с диска в utility-QoS, не на main (избегаем hang).
    static func warmup(media: [GeneratedMedia], pageSize: Int = 12) {
        let sorted = media.sorted { $0.createdAt > $1.createdAt }
        let firstPage = Array(sorted.prefix(pageSize))
        let localCandidates = firstPage.filter {
            !$0.imageURL.hasPrefix("placeholder-") && !$0.imageURL.hasPrefix("http")
        }
        let signature = "\(media.count)|" + localCandidates.map(\.id).joined(separator: ",")
        warmupLock.lock()
        if signature == lastWarmupSignature {
            warmupLock.unlock()
            print("🔥 [Gallery] Warmup: skipped (duplicate loadGeneratedMedia, same first page)")
            return
        }
        lastWarmupSignature = signature
        warmupLock.unlock()

        guard !localCandidates.isEmpty else {
            print("🔥 [Gallery] Warmup: media=\(media.count), firstPage local=0 (nothing to load)")
            return
        }

        // Копируем пути для фона — GeneratedMedia — value type.
        let snapshot = localCandidates.map { ($0.id, $0.thumbnailPath, $0.localPath) }
        DispatchQueue.global(qos: .utility).async {
            var thumbLoaded = 0
            var fullLoaded = 0
            var skippedInMemory = 0
            for (id, thumbPath, fullPath) in snapshot {
                if get(id) != nil {
                    skippedInMemory += 1
                    continue
                }
                if let img = UIImage(contentsOfFile: thumbPath) {
                    set(id, image: img)
                    thumbLoaded += 1
                } else if let img = UIImage(contentsOfFile: fullPath) {
                    set(id, image: img)
                    fullLoaded += 1
                }
            }
            DispatchQueue.main.async {
                print("🔥 [Gallery] Warmup: media=\(media.count), firstPage local=\(localCandidates.count), thumb→cache=\(thumbLoaded), full→cache=\(fullLoaded), skipped (already in NSCache)=\(skippedInMemory)")
            }
        }
    }
}

// MARK: - Masonry / плейсхолдер: aspect до декода UIImage

fileprivate enum GalleryPlaceholderLayout {
    static func aspectWidthOverHeight(forPlaceholderURL url: String) -> CGFloat {
        switch url {
        case "placeholder-portrait":  return 3.0 / 4.0
        case "placeholder-square":    return 1.0
        case "placeholder-landscape": return 4.0 / 3.0
        case "placeholder-tall":      return 2.0 / 3.0
        case "placeholder-wide":      return 16.0 / 9.0
        case "placeholder-video":     return 9.0 / 16.0
        default:                       return 1.0
        }
    }
}

/// Ширина/высота кадра из заголовка файла (без полного декода) — пока кэш пуст, masonry и ячейка не принимают 1:1 для локального вертикального фото.
fileprivate enum GalleryLocalFileAspect {
    static func displayWidthOverHeight(filePath: String) -> CGFloat? {
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }
        let url = URL(fileURLWithPath: filePath) as CFURL
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url, opts as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as NSDictionary?
        else { return nil }
        guard let pw = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let ph = props[kCGImagePropertyPixelHeight] as? NSNumber,
              ph.doubleValue > 0
        else { return nil }
        var w = CGFloat(truncating: pw)
        var h = CGFloat(truncating: ph)
        if let orientNum = props[kCGImagePropertyOrientation] as? NSNumber,
           let orientation = CGImagePropertyOrientation(rawValue: orientNum.uint32Value) {
            switch orientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                swap(&w, &h)
            default:
                break
            }
        }
        guard h > 0 else { return nil }
        return w / h
    }

    static func bestAspect(for media: GeneratedMedia) -> CGFloat? {
        if media.imageURL.hasPrefix("placeholder-") || media.imageURL.hasPrefix("http") { return nil }
        if let r = displayWidthOverHeight(filePath: media.thumbnailPath) { return r }
        if media.isVideo { return nil }
        return displayWidthOverHeight(filePath: media.localPath)
    }
}

fileprivate func galleryDisplayAspectWidthOverHeight(for media: GeneratedMedia) -> CGFloat {
    if media.imageURL.hasPrefix("http") {
        return 1.0
    }
    if media.imageURL.hasPrefix("placeholder-") {
        return GalleryPlaceholderLayout.aspectWidthOverHeight(forPlaceholderURL: media.imageURL)
    }
    if let img = GalleryThumbnailCache.get(media.id) {
        let h = img.size.height
        guard h > 0 else { return 1.0 }
        return img.size.width / h
    }
    if let r = GalleryLocalFileAspect.bestAspect(for: media) {
        return r
    }
    if media.isVideo {
        return 9.0 / 16.0
    }
    return 1.0
}

struct GalleryView: View {
    @EnvironmentObject var appState: AppState
    // Чип токенов в шапке временно отключён — при возврате раскомментируй вместе с `ProStatusBadge` в `galleryMainColumn`.
    // @ObservedObject private var tokenWallet = TokenWalletService.shared
    @ObservedObject private var generationJob = GenerationJobService.shared

    @State private var showMediaDetail = false
    @State private var selectedMedia: GeneratedImage? = nil
    @State private var displayCount: Int = 12
    @State private var isFirstPageReady = false
    @State private var lastLoadMoreTriggerId: String? = nil
    @State private var favoriteIds: Set<String> = []
    @State private var sortedMedia: [GeneratedImage] = []
    @State private var selectedFilter: GalleryFilter = .all
    @State private var showFilterPicker = false

    private let pageSize = 12
    private let favoriteIdsKey = "gallery_favorite_media_ids"

    /// Взаимоисключающие режимы сетки: все / избранное / только фото / только видео.
    private enum GalleryFilter: CaseIterable {
        case all
        case favourites
        case photos
        case videos

        var localizedTitle: String {
            switch self {
            case .all: return "gallery_filter_all".localized
            case .favourites: return "gallery_filter_favorites".localized
            case .photos: return "gallery_filter_photos".localized
            case .videos: return "gallery_filter_videos".localized
            }
        }
    }

    var filteredMedia: [GeneratedImage] {
        switch selectedFilter {
        case .all:
            return sortedMedia
        case .favourites:
            return sortedMedia.filter { favoriteIds.contains($0.id) }
        case .photos:
            return sortedMedia.filter { !$0.isVideo }
        case .videos:
            return sortedMedia.filter { $0.isVideo }
        }
    }

    var pagedMedia: [GeneratedImage] {
        Array(filteredMedia.prefix(displayCount))
    }

    private var hasMorePages: Bool {
        pagedMedia.count < filteredMedia.count
    }

    // Фильтр в шапке нужен только когда есть выбор между несколькими медиа; при 0-1 элементе скрываем кнопку как лишнее действие.
    private var shouldShowFilterButton: Bool {
        sortedMedia.count >= 2
    }

    /// В галерее только активные задания; завершённые с ошибкой не храним в `recentJobs` (см. `GenerationJobService`).
    private var visibleJobs: [LibraryGenerationJob] {
        // В процессе — только в режиме «Все», чтобы не смешивать черновики с узкими фильтрами.
        guard selectedFilter == .all else { return [] }
        return generationJob.recentJobs.filter { !$0.state.isFailed }
    }

    /// Разбиваем разметку — иначе SwiftUI не укладывается в лимит type-check.
    private var galleryBackgroundLayer: some View {
        AppTheme.Colors.background.ignoresSafeArea()
            .onAppear {
                let count = appState.generatedMedia.count
                Task(priority: .utility) {
                    await AppAnalyticsService.shared.reportGalleryOpened(photoCount: count)
                }
            }
    }

    @ViewBuilder
    private var galleryMainContentArea: some View {
        if filteredMedia.isEmpty && visibleJobs.isEmpty {
            if !isFirstPageReady {
                Spacer()
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                    .scaleEffect(1.3)
                Spacer()
            } else {
                ZStack {
                    emptyGalleryBackgroundSkeleton
                    emptyStateForeground
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if filteredMedia.isEmpty {
            galleryJobsOnlyList
        } else if !isFirstPageReady {
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                .scaleEffect(1.3)
            Spacer()
        } else {
            galleryMasonryGrid
        }
    }

    private var galleryMasonryGrid: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 12
            let columns = 2
            let cardWidth = max(50, (geometry.size.width - CGFloat(columns + 1) * spacing) / CGFloat(columns))

            ScrollView(showsIndicators: false) {
                // Активные задания — те же masonry-ячейки, что и готовые медиа (без отдельного блока «In progress»).
                let gridItems: [GalleryGridItem] = visibleJobs.map { .job($0) } + pagedMedia.map { .media($0) }

                MasonryGrid(
                    items: gridItems,
                    columns: columns,
                    spacing: spacing,
                    cardWidth: cardWidth
                ) { item in
                    switch item {
                    case .job(let job):
                        LibraryJobCardView(job: job, cardWidth: cardWidth) {
                            generationJob.retry(job: job)
                        }
                    case .media(let media):
                        MediaItemView(
                            media: media,
                            cardWidth: cardWidth,
                            isFavorite: favoriteIds.contains(media.id),
                            preloadedImage: GalleryThumbnailCache.get(media.id),
                            isAutoplayEnabled: pagedMedia.prefix(2).contains { $0.id == media.id }
                        ) {
                            selectedMedia = media
                            showMediaDetail = true
                        }
                        .onAppear {
                            guard hasMorePages else { return }
                            guard let idx = pagedMedia.firstIndex(where: { $0.id == media.id }) else { return }
                            let thresholdIndex = max(0, pagedMedia.count - 4)
                            guard idx >= thresholdIndex else { return }
                            guard lastLoadMoreTriggerId != media.id else { return }
                            lastLoadMoreTriggerId = media.id
                            displayCount = min(displayCount + pageSize, filteredMedia.count)
                        }
                    }
                }
                .padding(.horizontal, spacing)
                .padding(.top, 20)

                Color.clear.frame(height: 100)
            }
        }
        .background(AppTheme.Colors.background.ignoresSafeArea())
    }

    private var galleryJobsOnlyList: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 12
            let columns = 2
            let cardWidth = max(50, (geometry.size.width - CGFloat(columns + 1) * spacing) / CGFloat(columns))

            ScrollView(showsIndicators: false) {
                let gridItems = visibleJobs.map { GalleryGridItem.job($0) }

                MasonryGrid(
                    items: gridItems,
                    columns: columns,
                    spacing: spacing,
                    cardWidth: cardWidth
                ) { item in
                    switch item {
                    case .job(let job):
                        LibraryJobCardView(job: job, cardWidth: cardWidth) {
                            generationJob.retry(job: job)
                        }
                    case .media:
                        EmptyView()
                    }
                }
                .padding(.horizontal, spacing)
                .padding(.top, 20)

                Color.clear.frame(height: 100)
            }
        }
        .background(AppTheme.Colors.background.ignoresSafeArea())
    }

    private var galleryMainColumn: some View {
        VStack(spacing: 0) {
            TopNavigationBar(
                title: "gallery_title".localized,
                showBackButton: false,
                customRightContent: AnyView(
                    HStack(spacing: 12) {
                        if shouldShowFilterButton {
                            Button {
                                showFilterPicker = true
                            } label: {
                                Image(systemName: "line.3.horizontal.decrease")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(selectedFilter == .all ? AppTheme.Colors.textPrimary : AppTheme.Colors.primary)
                                    .opacity(0.9)
                            }
                            .appPlainButtonStyle()
                            .accessibilityLabel(Text("gallery_filter_title".localized))
                        }

                        // ProStatusBadge(
                        //     tokenBalance: tokenWallet.balance,
                        //     action: { appState.presentPaywallFullscreen() }
                        // )
                    }
                ),
                backgroundColor: AppTheme.Colors.background
            )
            galleryMainContentArea
        }
        .overlay(alignment: .bottom) {
            BottomNavigationBar()
        }
    }

    @ViewBuilder
    private var galleryMediaDetailOverlay: some View {
        if showMediaDetail, let media = selectedMedia,
           !filteredMedia.isEmpty,
           filteredMedia.contains(where: { $0.id == media.id }) {
            MediaDetailView(
                allMedia: filteredMedia,
                currentMedia: media,
                hideActionButtons: false,
                isEffectReferencePickMode: false,
                onDismiss: {
                    showMediaDetail = false
                    appState.handleMediaDetailDismissed()
                },
                onEffectReferencePicked: nil,
                showDeleteInTopBar: true,
                customTrailingActionIcon: { current in
                    favoriteIds.contains(current.id) ? "Star Fill" : "Star"
                },
                customTrailingActionIconColor: { current in
                    favoriteIds.contains(current.id) ? .yellow : AppTheme.Colors.textPrimary
                },
                customTrailingActionColor: Color.customPurple.opacity(0.72),
                customTrailingAction: { current in
                    toggleFavorite(for: current)
                }
            )
            .environmentObject(appState)
            .transition(.identity)
            .zIndex(1)
        }
    }

    var body: some View {
        ZStack {
            galleryBackgroundLayer
            galleryMainColumn
            galleryMediaDetailOverlay
        }
        .onAppear {
            loadFavorites()
            lastLoadMoreTriggerId = nil
            displayCount = pageSize
            // Экран появляется мгновенно с лоадером; сортировка + прогрев кэша первой страницы
            // идут в фоне, грид показывается только когда thumbnail'ы уже в памяти.
            isFirstPageReady = false
            Task {
                let media = appState.generatedMedia
                let sorted = media.sorted { $0.createdAt > $1.createdAt }
                let firstPage = Array(sorted.prefix(pageSize))
                // Прогрев кэша первой страницы с диска до показа грида
                let uncached = firstPage.filter {
                    !$0.imageURL.hasPrefix("placeholder-") && !$0.imageURL.hasPrefix("http")
                        && GalleryThumbnailCache.get($0.id) == nil
                }
                if !uncached.isEmpty {
                    var thumbFromDisk = 0
                    var fullSizeFromDisk = 0
                    await withTaskGroup(of: (String, UIImage?, Bool).self) { group in
                        for item in uncached {
                            let thumbPath = item.thumbnailPath
                            let fallback = item.localPath
                            let id = item.id
                            group.addTask {
                                if let img = UIImage(contentsOfFile: thumbPath) {
                                    return (id, img, true)
                                }
                                if let img = UIImage(contentsOfFile: fallback) {
                                    return (id, img, false)
                                }
                                return (id, nil, false)
                            }
                        }
                        for await (id, img, fromThumb) in group {
                            if let img {
                                GalleryThumbnailCache.set(id, image: img)
                                if fromThumb { thumbFromDisk += 1 } else { fullSizeFromDisk += 1 }
                            }
                        }
                    }
                    print("📸 [Gallery] First page (onAppear): loaded \(thumbFromDisk) from thumbnail file(s), \(fullSizeFromDisk) from full-size file(s)")
                } else {
                    print("📸 [Gallery] First page (onAppear): all from memory cache — no disk read")
                }
                await MainActor.run {
                    sortedMedia = sorted
                    isFirstPageReady = true
                }
            }
        }
        .onChange(of: appState.generatedMedia.count) { _, _ in
            refreshSortedMedia()
        }
        .onChange(of: showMediaDetail) { _, isShown in
            if !isShown {
                refreshSortedMedia()
            }
        }
        .onChange(of: hasAnyFavorites) { _, hasFavorites in
            if !hasFavorites, selectedFilter == .favourites {
                selectedFilter = .all
            }
        }
        // Только id первой страницы — не map по всему массиву (иначе при 200+ фото каждый кадр тяжёлый).
        .task(id: Array(filteredMedia.prefix(pageSize)).map(\.id).joined(separator: ",")) {
            guard !filteredMedia.isEmpty else {
                isFirstPageReady = false
                try? await Task.sleep(nanoseconds: 350_000_000)
                if filteredMedia.isEmpty {
                    isFirstPageReady = true
                }
                return
            }
            isFirstPageReady = true
            // Фоновый прогрев первой страницы: кладём в статический кэш,
            // чтобы при следующем заходе на вкладку картинки были мгновенно.
            let firstPage = Array(filteredMedia.prefix(pageSize))
            let localItems = firstPage.filter {
                !$0.imageURL.hasPrefix("placeholder-") && !$0.imageURL.hasPrefix("http")
                    && GalleryThumbnailCache.get($0.id) == nil
            }
            guard !localItems.isEmpty else { return }
            var thumbFromDisk = 0
            var fullSizeFromDisk = 0
            await withTaskGroup(of: (String, UIImage?, Bool).self) { group in
                for item in localItems {
                    let thumbPath = item.thumbnailPath
                    let fallback = item.localPath
                    let id = item.id
                    group.addTask(priority: .userInitiated) {
                        if let img = UIImage(contentsOfFile: thumbPath) {
                            return (id, img, true)
                        }
                        if let img = UIImage(contentsOfFile: fallback) {
                            return (id, img, false)
                        }
                        return (id, nil, false)
                    }
                }
                for await (id, img, fromThumb) in group {
                    if let img {
                        GalleryThumbnailCache.set(id, image: img)
                        if fromThumb { thumbFromDisk += 1 } else { fullSizeFromDisk += 1 }
                    }
                }
            }
            print("📸 [Gallery] First page (prefetch): loaded \(thumbFromDisk) from thumbnail file(s), \(fullSizeFromDisk) from full-size file(s)")
        }
        .confirmationDialog("gallery_filter_title".localized, isPresented: $showFilterPicker) {
            Button(GalleryFilter.all.localizedTitle) {
                selectedFilter = .all
            }
            Button(GalleryFilter.favourites.localizedTitle) {
                selectedFilter = .favourites
            }
            Button(GalleryFilter.photos.localizedTitle) {
                selectedFilter = .photos
            }
            Button(GalleryFilter.videos.localizedTitle) {
                selectedFilter = .videos
            }
            Button("cancel".localized, role: .cancel) {}
        }

        .themeAware()
        .themeAnimation()
    }

    private func loadFavorites() {
        let raw = UserDefaults.standard.string(forKey: favoriteIdsKey) ?? ""
        favoriteIds = Set(raw.split(separator: ",").map(String.init))
    }

    private func saveFavorites() {
        let snapshot = favoriteIds.sorted().joined(separator: ",")
        Task.detached(priority: .utility) {
            UserDefaults.standard.set(snapshot, forKey: favoriteIdsKey)
        }
    }

    // При добавлении в избранное отправляем "предложение в витрину" в глобальную БД.
    private func toggleFavorite(for media: GeneratedImage) {
        let isCurrentlyFavorite = favoriteIds.contains(media.id)
        if isCurrentlyFavorite {
            favoriteIds.remove(media.id)
            saveFavorites()
            if !showMediaDetail {
                refreshSortedMedia()
            }
            return
        }

        favoriteIds.insert(media.id)
        saveFavorites()
        if !showMediaDetail {
            refreshSortedMedia()
        }

        // Не блокируем UI: submit-showcase-candidate с publish_now=false — кандидат в модерации (на Edge: is_active=false до approve).
        Task.detached(priority: .utility) {
            SupabaseService.shared.submitShowcaseCandidate(generationId: media.id, publishNow: false) { _ in }
        }
    }

    private func refreshSortedMedia() {
        sortedMedia = appState.generatedMedia.sorted { $0.createdAt > $1.createdAt }
    }

    private var hasAnyFavorites: Bool {
        appState.generatedMedia.contains { favoriteIds.contains($0.id) }
    }
    
    /// Текст и кнопка поверх фоновой сетки; блок по вертикали по центру доступной области (с запасом под таббар).
    @ViewBuilder private var emptyStateForeground: some View {
        VStack {
            Spacer(minLength: 0)

            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    Text("library_empty_title".localized)
                        .font(AppTheme.Typography.title)
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("library_empty_subtitle".localized)
                        .font(AppTheme.Typography.body)
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                Button(action: { appState.currentScreen = .effectsHome }) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .bold))
                        Text("library_empty_cta".localized)
                            .font(AppTheme.Typography.buttonSmall)
                    }
                    .foregroundColor(AppTheme.Colors.onPrimaryText)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(AppTheme.Colors.primaryGradient)
                    .clipShape(Capsule())
                }
                .appPlainButtonStyle()
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 100)
    }

    /// Еле заметные квадраты 1:1 с тем же cardWidth, что и у MasonryGrid; фон на всю высоту области под шапкой.
    private var emptyGalleryBackgroundSkeleton: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let spacing: CGFloat = 12
            let columns = 2
            let cardWidth = max(50, (w - CGFloat(columns + 1) * spacing) / CGFloat(columns))
            let rowStride = cardWidth + spacing
            let rowCount = max(
                8,
                Int(ceil((h + spacing) / rowStride)) + 2
            )

            ZStack(alignment: .top) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { _ in
                        VStack(spacing: spacing) {
                            ForEach(0..<rowCount, id: \.self) { _ in
                                emptyMockSquareTile(side: cardWidth)
                            }
                        }
                    }
                }
                .padding(.horizontal, spacing)

                // Маска на вложенном HStack часто не совпадает с высотой `GeometryReader` и не гасит «хвост» плиток.
                // Скрам тем же цветом, что и фон экрана: к низу плавно перекрываем плитки; на 75% высоты (25% от низа) уже непрозрачный фон.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.52),
                        .init(color: AppTheme.Colors.background.opacity(0.55), location: 0.64),
                        .init(color: AppTheme.Colors.background, location: 0.75),
                        .init(color: AppTheme.Colors.background, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: w, height: h)
                .allowsHitTesting(false)
            }
            .frame(width: w, height: h, alignment: .top)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    /// Подложка плиток пустой галереи: без обводки и иконок; низкий контраст к `background`, сетка едва читается.
    private var emptyMockTileFill: Color {
        switch AppTheme.current {
        case .dark:
            return Color.white.opacity(0.055)
        case .light:
            return Color.black.opacity(0.048)
        }
    }

    private func emptyMockSquareTile(side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(emptyMockTileFill)
            .frame(width: side, height: side)
    }
}

struct LibraryJobCardView: View {
    let job: LibraryGenerationJob
    let cardWidth: CGFloat
    let onRetry: () -> Void

    private var tileWidthOverHeight: CGFloat {
        Self.aspectWidthOverHeight(for: job.request)
    }

    private var tileHeight: CGFloat {
        Self.tileImageHeight(cardWidth: cardWidth, request: job.request)
    }

    /// Высота только плитки (картинка); для masonry — см. `estimatedMasonryHeight`.
    static func tileImageHeight(cardWidth: CGFloat, request: GenerationJobRequest) -> CGFloat {
        cardWidth / aspectWidthOverHeight(for: request)
    }

    static func aspectWidthOverHeight(for request: GenerationJobRequest) -> CGFloat {
        switch request {
        case .promptPhoto(_, let aspect, _, _):
            // Без явного aspect (i2i) плитка — нейтральный квадрат до готового результата.
            return parseAspectRatioString(aspect) ?? 1
        case .promptVideo(_, _, _, let aspect, _, _):
            return parseAspectRatioString(aspect) ?? (9.0 / 16.0)
        case .effect(let preset, _):
            return parseAspectRatioString(preset.aspectRatio) ?? (9.0 / 16.0)
        }
    }

    /// Оценка полной высоты ячейки в сетке (у failed под плиткой текст и retry).
    static func estimatedMasonryHeight(cardWidth: CGFloat, job: LibraryGenerationJob) -> CGFloat {
        let tile = tileImageHeight(cardWidth: cardWidth, request: job.request)
        if job.state.isFailed { return tile + 118 }
        return tile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: job.state.isFailed ? 10 : 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)

                if job.state.isFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.error)
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                        .scaleEffect(1.15)
                }
            }
            .frame(width: cardWidth, height: tileHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if job.state.isFailed {
                Text(job.state.localizedSubtitle)
                    .font(AppTheme.Typography.caption)
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onRetry) {
                    Text("library_job_retry".localized)
                        .font(AppTheme.Typography.caption)
                        .foregroundColor(AppTheme.Colors.onPrimaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(AppTheme.Colors.primaryGradient, in: Capsule())
                }
                .appPlainButtonStyle()
            }
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    private static func parseAspectRatioString(_ raw: String?) -> CGFloat? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let w = Double(parts[0]), let h = Double(parts[1]), h > 0 else { return nil }
        return CGFloat(w / h)
    }
}

/// Одна строка masonry: либо готовое медиа, либо активное задание (плейсхолдер без отдельной секции).
private enum GalleryGridItem: Identifiable {
    case job(LibraryGenerationJob)
    case media(GeneratedMedia)

    var id: String {
        switch self {
        case .job(let j): return "job-\(j.id)"
        case .media(let m): return m.id
        }
    }
}

struct MediaItemView: View {
    let media: GeneratedImage
    let cardWidth: CGFloat
    let isFavorite: Bool
    let preloadedImage: UIImage?
    let isAutoplayEnabled: Bool
    let onTap: () -> Void

    init(media: GeneratedImage, cardWidth: CGFloat, isFavorite: Bool = false, preloadedImage: UIImage? = nil, isAutoplayEnabled: Bool = false, onTap: @escaping () -> Void) {
        self.media = media
        self.cardWidth = cardWidth
        self.isFavorite = isFavorite
        self.preloadedImage = preloadedImage
        self.isAutoplayEnabled = isAutoplayEnabled
        self.onTap = onTap
        _loadedImage = State(initialValue: preloadedImage)
        // До декода: `preloadedImage` может прийти без записи в NSCache; иначе — метаданные файла / плейсхолдер (не 1:1 по умолчанию).
        let initialAR: CGFloat = {
            if let img = preloadedImage ?? GalleryThumbnailCache.get(media.id) {
                let h = img.size.height
                return h > 0 ? img.size.width / h : galleryDisplayAspectWidthOverHeight(for: media)
            }
            return galleryDisplayAspectWidthOverHeight(for: media)
        }()
        _aspectRatio = State(initialValue: initialAR)
    }

    // Асинхронно загруженное локальное изображение
    @State private var loadedImage: UIImage?
    @State private var aspectRatio: CGFloat

    /// Плейсхолдеры пустой сетки: в light полупрозрачные тинты читаются на белом; в dark те же opacity на `cardBackground` почти исчезают — даём отдельную заливку и обводку по акценту.
    private func placeholderInfo(for url: String) -> (icon: String, text: String, lightFill: Color, accent: Color) {
        switch url {
        case "placeholder-portrait":  return ("person.crop.rectangle", "Portrait", Color.blue.opacity(0.4), Color.blue)
        case "placeholder-square":    return ("square.on.square", "Square", Color.green.opacity(0.4), Color.green)
        case "placeholder-landscape": return ("rectangle.landscape", "Landscape", Color.orange.opacity(0.4), Color.orange)
        case "placeholder-tall":      return ("rectangle.portrait", "Tall", Color.purple.opacity(0.4), Color.purple)
        case "placeholder-wide":      return ("rectangle.fill", "Wide", Color.red.opacity(0.4), Color.red)
        case "placeholder-video":     return ("video.fill", "Video", Color.pink.opacity(0.4), Color.pink)
        default:                      return ("photo.fill", "Photo", Color.gray.opacity(0.4), Color(red: 0.55, green: 0.56, blue: 0.6))
        }
    }

    var body: some View {
        let height = cardWidth / aspectRatio

        ZStack(alignment: .topTrailing) {
            Group {
                if media.imageURL.hasPrefix("placeholder-") {
                    let info = placeholderInfo(for: media.imageURL)
                    let isDark = AppTheme.current == .dark
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isDark ? AppTheme.Colors.cardBackground : info.lightFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isDark ? info.accent.opacity(0.5) : Color.clear, lineWidth: 1)
                        )
                        .frame(width: cardWidth, height: height)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: info.icon)
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(isDark ? info.accent.opacity(0.92) : AppTheme.Colors.textPrimary.opacity(0.85))
                                Text(info.text)
                                    .font(AppTheme.Typography.caption)
                                    .foregroundColor(isDark ? AppTheme.Colors.textSecondary : AppTheme.Colors.textPrimary.opacity(0.85))
                            }
                        )

                } else if media.isVideo {
                    galleryMediaPreview(
                        image: loadedImage ?? preloadedImage ?? GalleryThumbnailCache.get(media.id),
                        motionURL: media.imageURL,
                        shouldPlayMotion: isAutoplayEnabled,
                        height: height
                    )

                } else if media.imageURL.hasPrefix("http") {
                    galleryMediaPreview(
                        imageURL: URL(string: media.imageURL),
                        height: height
                    )

                } else {
                    // Локальный файл: @State → preload → статический кэш → loader
                    galleryMediaPreview(
                        image: loadedImage ?? preloadedImage ?? GalleryThumbnailCache.get(media.id),
                        height: height
                    )
                }
            }
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.yellow)
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task(id: media.id) {
            if media.imageURL.hasPrefix("placeholder-") {
                aspectRatio = GalleryPlaceholderLayout.aspectWidthOverHeight(forPlaceholderURL: media.imageURL)
                return
            }
            if media.isVideo {
                await loadLocalThumbnailIfNeeded()
                return
            }
            if media.imageURL.hasPrefix("http") { return }
            // Уже есть в памяти — обновляем aspect ratio если нужно
            if let cached = loadedImage ?? GalleryThumbnailCache.get(media.id) {
                let ratio = cached.size.width / cached.size.height
                if loadedImage == nil { loadedImage = cached }
                if abs(aspectRatio - ratio) > 0.01 { aspectRatio = ratio }
                return
            }
            await loadLocalThumbnailIfNeeded()
        }
        .onAppear {
            if media.imageURL.hasPrefix("placeholder-") {
                aspectRatio = GalleryPlaceholderLayout.aspectWidthOverHeight(forPlaceholderURL: media.imageURL)
            } else if media.isVideo {
                aspectRatio = galleryDisplayAspectWidthOverHeight(for: media)
            }
        }
    }

    @ViewBuilder
    private func galleryMediaPreview(
        imageURL: URL? = nil,
        image: UIImage? = nil,
        motionURL: String? = nil,
        shouldPlayMotion: Bool = false,
        height: CGFloat
    ) -> some View {
        PreviewMediaView(
            imageURL: imageURL,
            image: image,
            motionURL: motionURL,
            shouldPlayMotion: shouldPlayMotion,
            debugContext: "gallery id=\(media.id)"
        ) {
            IconLoadingPlaceholder()
        }
        .frame(width: cardWidth, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func loadLocalThumbnailIfNeeded() async {
        if let cached = loadedImage ?? GalleryThumbnailCache.get(media.id) {
            let ratio = cached.size.width / cached.size.height
            await MainActor.run {
                if loadedImage == nil { loadedImage = cached }
                if abs(aspectRatio - ratio) > 0.01 { aspectRatio = ratio }
            }
            return
        }

        let thumbPath = media.thumbnailPath
        let fallbackPath = media.isVideo ? nil : media.localPath
        let img = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: thumbPath) ?? fallbackPath.flatMap { UIImage(contentsOfFile: $0) }
        }.value
        if let img {
            GalleryThumbnailCache.set(media.id, image: img)
            let ratio = img.size.width / img.size.height
            await MainActor.run {
                loadedImage = img
                aspectRatio = ratio
            }
        }
    }
}

// MARK: - Masonry Grid Layout
struct MasonryGrid<Content: View, T: Identifiable>: View {
    let items: [T]
    let columns: Int
    let spacing: CGFloat
    let cardWidth: CGFloat
    let content: (T) -> Content
    
    init(
        items: [T],
        columns: Int,
        spacing: CGFloat,
        cardWidth: CGFloat,
        @ViewBuilder content: @escaping (T) -> Content
    ) {
        self.items = items
        self.columns = columns
        self.spacing = spacing
        self.cardWidth = cardWidth
        self.content = content
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columns, id: \.self) { columnIndex in
                VStack(spacing: spacing) {
                    ForEach(itemsForColumn(columnIndex), id: \.id) { item in
                        content(item)
                    }
                }
            }
        }
    }
    
    private func itemsForColumn(_ columnIndex: Int) -> [T] {
        // Создаем массивы для каждой колонки и отслеживаем их высоты
        var columnItems: [[T]] = Array(repeating: [], count: columns)
        var columnHeights: [CGFloat] = Array(repeating: 0, count: columns)
        
        // Распределяем элементы по колонкам, учитывая их высоту
        for item in items {
            // Находим колонку с наименьшей высотой
            let shortestColumnIndex = columnHeights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            
            // Добавляем элемент в эту колонку
            columnItems[shortestColumnIndex].append(item)
            
            // Обновляем высоту колонки (используем приблизительную высоту на основе aspect ratio)
            let itemHeight = getItemHeight(item)
            columnHeights[shortestColumnIndex] += itemHeight + spacing
        }
        
        return columnItems[columnIndex]
    }
    
    private func getItemHeight(_ item: T) -> CGFloat {
        if let cell = item as? GalleryGridItem {
            switch cell {
            case .job(let job):
                return LibraryJobCardView.estimatedMasonryHeight(cardWidth: cardWidth, job: job)
            case .media(let media):
                return cardWidth / galleryDisplayAspectWidthOverHeight(for: media)
            }
        }
        if let media = item as? GeneratedImage {
            return cardWidth / galleryDisplayAspectWidthOverHeight(for: media)
        }

        return cardWidth
    }
} 