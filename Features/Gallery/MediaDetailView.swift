import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct MediaDetailView: View {
    let allMedia: [GeneratedImage]
    let hideActionButtons: Bool
    /// Режим выбора референс-фото под сценарий эффекта (нижняя кнопка «Выбрать это фото-референс»).
    let isEffectReferencePickMode: Bool
    @State private var currentIndex: Int
    let onDismiss: () -> Void
    let onEffectReferencePicked: ((GeneratedImage) -> Void)?
    let customTopRightIcon: ((GeneratedImage) -> String)?
    let customTopRightIconColor: ((GeneratedImage) -> Color)?
    let customTopRightAction: ((GeneratedImage) -> Void)?
    let showDeleteInTopBar: Bool
    let customTrailingActionIcon: ((GeneratedImage) -> String)?
    let customTrailingActionIconColor: ((GeneratedImage) -> Color)?
    let customTrailingActionColor: Color
    let customTrailingAction: ((GeneratedImage) -> Void)?
    @EnvironmentObject var appState: AppState
    @State private var isCurrentImageZoomed = false
    @State private var showDeleteConfirmation = false
    @State private var updatedAllMedia: [GeneratedImage] // Локальная копия для обновления
    @State private var internalIndex: Int = 1 // Внутренний индекс для кольцевой галереи
    @State private var isJumping: Bool = false // Флаг для отслеживания перепрыгивания
    @State private var isUIHidden: Bool = false // Состояние скрытия UI элементов
    @State private var showDebugMetaSheet = false
    // Glass-подложка для action-кнопок: не спорит с контентом, выглядит легче плотных цветных кругов.
    private let glassButtonShape = Circle()
    private let glassButtonSize: CGFloat = 56
    /// Нижний бар: share крупнее, download и избранное — меньше при том же круге `glassButtonSize`.
    private let mediaDetailShareIconPointSize: CGFloat = 24
    private let mediaDetailBottomCompactIconPointSize: CGFloat = 20

    // Computed property для определения режима одного изображения
    private var isSingleImageMode: Bool {
        return updatedAllMedia.count == 1
    }

    /// Подложка под шапку: в dark — лёгкое затемнение для светлых иконок; в light — засветление, чтобы тёмные `textPrimary` читались на ярком фото.
    private let mediaDetailTopChromeOpacity: Double = 0.5

    /// Верхний inset окна: активная сцена + key window — `windows.first` часто не key и даёт 0 для статус-бара.
    #if canImport(UIKit)
    private static func keyWindowSafeAreaTop() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let scene else { return 0 }
        let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        return window?.safeAreaInsets.top ?? 0
    }

    private static func keyWindowSafeAreaBottom() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let scene else { return 0 }
        let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        return window?.safeAreaInsets.bottom ?? 0
    }
    #else
    private static func keyWindowSafeAreaTop() -> CGFloat { 0 }
    private static func keyWindowSafeAreaBottom() -> CGFloat { 0 }
    #endif

    /// Скрытие нижних кнопок: сдвиг вниз больше высоты блока + home indicator, иначе край остаётся видимым.
    private var bottomControlsHideOffset: CGFloat {
        glassButtonSize + 52 + Self.keyWindowSafeAreaBottom()
    }
    
    // Создаем расширенный массив: [последний, все изображения, первое]
    private var extendedMedia: [GeneratedImage] {
        guard updatedAllMedia.count > 1 else { return updatedAllMedia }
        var extended = updatedAllMedia
        extended.insert(updatedAllMedia.last!, at: 0) // Добавляем последний элемент в начало
        extended.append(updatedAllMedia.first!) // Добавляем первый элемент в конец
        return extended
    }
    
    // Определяем, нужно ли использовать кольцевую галерею
    private var shouldUseCircularGallery: Bool {
        return updatedAllMedia.count > 1
    }
    
    init(
        allMedia: [GeneratedImage],
        currentMedia: GeneratedImage,
        hideActionButtons: Bool = false,
        isEffectReferencePickMode: Bool = false,
        onDismiss: @escaping () -> Void,
        onEffectReferencePicked: ((GeneratedImage) -> Void)? = nil,
        customTopRightIcon: ((GeneratedImage) -> String)? = nil,
        customTopRightIconColor: ((GeneratedImage) -> Color)? = nil,
        customTopRightAction: ((GeneratedImage) -> Void)? = nil,
        showDeleteInTopBar: Bool = false,
        customTrailingActionIcon: ((GeneratedImage) -> String)? = nil,
        customTrailingActionIconColor: ((GeneratedImage) -> Color)? = nil,
        customTrailingActionColor: Color = Color.red.opacity(0.5),
        customTrailingAction: ((GeneratedImage) -> Void)? = nil
    ) {
        self.allMedia = allMedia
        self.hideActionButtons = hideActionButtons
        self.isEffectReferencePickMode = isEffectReferencePickMode
        self.onDismiss = onDismiss
        self.onEffectReferencePicked = onEffectReferencePicked
        self.customTopRightIcon = customTopRightIcon
        self.customTopRightIconColor = customTopRightIconColor
        self.customTopRightAction = customTopRightAction
        self.showDeleteInTopBar = showDeleteInTopBar
        self.customTrailingActionIcon = customTrailingActionIcon
        self.customTrailingActionIconColor = customTrailingActionIconColor
        self.customTrailingActionColor = customTrailingActionColor
        self.customTrailingAction = customTrailingAction
        // Находим индекс текущего изображения
        let index = allMedia.firstIndex { $0.id == currentMedia.id } ?? 0
        self._currentIndex = State(initialValue: index)
        self._updatedAllMedia = State(initialValue: allMedia)
        self._internalIndex = State(initialValue: allMedia.count > 1 ? index + 1 : index) // +1 только для кольцевой галереи
    }
    
    private var currentMedia: GeneratedImage {
        guard currentIndex >= 0 && currentIndex < updatedAllMedia.count else {
            return updatedAllMedia.first!
        }
        return updatedAllMedia[currentIndex]
    }
    
    /// Расстояние страницы `extendedMedia` до текущей (для прогрева кэша и AV только в окне ±2 — не монтируем сотни тяжёлых слайдов сразу: `TabView` создаёт страницы лениво).
    private func galleryNeighborDistance(extendedIndex: Int) -> Int {
        if !shouldUseCircularGallery {
            return extendedIndex == currentIndex ? 0 : 999
        }
        return abs(extendedIndex - internalIndex)
    }

    /// Синхронный прогрев RAM/диска в `ZoomableImageView` только в окне ±2 вокруг активной страницы.
    private func isEagerCacheSlide(extendedIndex: Int) -> Bool {
        galleryNeighborDistance(extendedIndex: extendedIndex) <= 2
    }

    /// После свайпа `TabView`: обновляем реальный `currentIndex` и бесшовное кольцо на дубликатах краёв (как `EffectDetailPresetCarousel`).
    private func commitGalleryPage(_ newValue: Int) {
        guard shouldUseCircularGallery else { return }
        isCurrentImageZoomed = false
        if newValue == 0 {
            currentIndex = updatedAllMedia.count - 1
            jumpGallerySilently(to: updatedAllMedia.count)
            return
        }
        if newValue == extendedMedia.count - 1 {
            currentIndex = 0
            jumpGallerySilently(to: 1)
            return
        }
        currentIndex = newValue - 1
    }

    private func jumpGallerySilently(to target: Int) {
        DispatchQueue.main.async {
            isJumping = true
            internalIndex = target
            DispatchQueue.main.async {
                isJumping = false
            }
        }
    }

    /// После удаления/программной смены `currentIndex` подгоняем `internalIndex` под расширенный массив `[last]+items+[first]`.
    private func alignInternalIndexToCurrent() {
        guard shouldUseCircularGallery else {
            internalIndex = 0
            return
        }
        let target = min(max(currentIndex, 0), updatedAllMedia.count - 1) + 1
        guard internalIndex != target else { return }
        jumpGallerySilently(to: target)
    }

    @ViewBuilder
    private func galleryPageContent(geometry: GeometryProxy, pageIndex: Int, media: GeneratedImage) -> some View {
        let dist = galleryNeighborDistance(extendedIndex: pageIndex)
        let isActivePage = !shouldUseCircularGallery || pageIndex == internalIndex
        ZStack {
            if media.imageURL.hasPrefix("placeholder-") {
                let info = placeholderInfo(for: media)
                Rectangle()
                    .fill(info.color)
                    .overlay(
                        VStack(spacing: 16) {
                            Image(systemName: info.icon)
                                .font(.system(size: 60))
                                .foregroundColor(AppTheme.Colors.textPrimary.opacity(0.8))
                            Text(info.text)
                                .font(AppTheme.Typography.headline)
                                .foregroundColor(AppTheme.Colors.textPrimary.opacity(0.8))
                        }
                    )
                    .aspectRatio(contentMode: .fit)
            } else if media.isVideo {
                MediaVideoPlayer(
                    mediaURL: media.imageURL,
                    shouldPlay: isActivePage,
                    preloadsWhenPaused: dist > 0 && dist <= 2,
                    isMuted: false,
                    playbackVolumeOverride: 0.07,
                    usesDiskCache: false,
                    expandsVideoToIgnoreSafeArea: true
                )
            } else {
                ZoomableImageView(
                    imageURL: media.imageURL,
                    eagerSyncFromCache: isEagerCacheSlide(extendedIndex: pageIndex),
                    onZoomChange: { isZoomed in
                        if isActivePage {
                            isCurrentImageZoomed = isZoomed
                        }
                    }
                )
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
    }

    var body: some View {
        ZStack {
            AppTheme.Colors.background
                .ignoresSafeArea()
            
            // Карусель: `TabView(.page)` держит в иерархии в основном текущую и соседние страницы (лениво), а не весь `extendedMedia` в одном `HStack` — при большой галерее без этого лагает.
            GeometryReader { geometry in
                Group {
                    if shouldUseCircularGallery {
                        TabView(selection: $internalIndex) {
                            ForEach(Array(extendedMedia.enumerated()), id: \.offset) { pageIndex, media in
                                galleryPageContent(geometry: geometry, pageIndex: pageIndex, media: media)
                                    .tag(pageIndex)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scrollDisabled(isCurrentImageZoomed)
                        .transaction { transaction in
                            if isJumping {
                                transaction.disablesAnimations = true
                            }
                        }
                        .onChange(of: internalIndex) { _, newValue in
                            commitGalleryPage(newValue)
                        }
                    } else if let media = updatedAllMedia.first {
                        galleryPageContent(geometry: geometry, pageIndex: 0, media: media)
                    }
                }
            }
            .clipped()
            .ignoresSafeArea()

            // Оверлей: GeometryReader + ignoresSafeArea(.top) — иначе safeAreaInsets.top у контента 0 и полоска статуса нулевой высоты.
            GeometryReader { geo in
                let statusInset = max(geo.safeAreaInsets.top, Self.keyWindowSafeAreaTop())
                // Раньше было фиксированное -100: при большом safeArea.top часть шапки оставалась на экране — сдвигаем на фактическую высоту блока + запас.
                let topChromeBarHeight: CGFloat = 8 + 52
                let topChromeHideOffset = statusInset + topChromeBarHeight + 28

                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        // Один общий .background у всего блока — иначе полоска статуса и шапка дают разную «толщину» скрима поверх фото.
                        Color.clear
                            .frame(height: statusInset)

                        ZStack {
                        HStack {
                            Button(action: {
                                onDismiss()
                            }) {
                                Image(systemName: "chevron.left")
                                    .font(.title2)
                                    .foregroundColor(AppTheme.Colors.textPrimary)
                                    .frame(width: 44, height: 44)
                            }
                            .appPlainButtonStyle()

                            Spacer()

                            HStack(spacing: 0) {
                                if appState.isDebugModeEnabled {
                                    Button(action: { showDebugMetaSheet = true }) {
                                        Image(systemName: "info.circle")
                                            .font(.system(size: 22, weight: .regular))
                                            .foregroundColor(AppTheme.Colors.textPrimary)
                                            .frame(width: 44, height: 44)
                                    }
                                    .appPlainButtonStyle()
                                    .offset(y: -2)
                                }
                                if let customTopRightAction {
                                    Button(action: {
                                        customTopRightAction(currentMedia)
                                    }) {
                                        iconImage(
                                            named: customTopRightIcon?(currentMedia) ?? "Star",
                                            color: customTopRightIconColor?(currentMedia) ?? AppTheme.Colors.textPrimary,
                                            size: 22
                                        )
                                        .offset(y: -2)
                                        .frame(width: 44, height: 44)
                                    }
                                    .appPlainButtonStyle()
                                }
                                if !appState.isDebugModeEnabled && customTopRightAction == nil {
                                    Color.clear
                                        .frame(width: 44, height: 44)
                                }
                                if showDeleteInTopBar && !hideActionButtons {
                                    Button(action: {
                                        showDeleteConfirmation = true
                                    }) {
                                        Group {
                                            if deleteService.isDeleting {
                                                ProgressView()
                                                    .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                                                    .scaleEffect(0.7)
                                            } else {
                                                IconView("Delete", size: 18, color: AppTheme.Colors.textPrimary)
                                                    .frame(width: 24, height: 24)
                                            }
                                        }
                                        .frame(width: 44, height: 44)
                                    }
                                    .appPlainButtonStyle()
                                    .offset(y: -2)
                                    .disabled(deleteService.isDeleting)
                                }
                            }
                        }

                        if updatedAllMedia.count > 1 {
                            Text("\(currentIndex + 1) of \(updatedAllMedia.count)")
                                .font(AppTheme.Typography.body)
                                .foregroundColor(AppTheme.Colors.textPrimary)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    }
                    .background(
                        (AppTheme.current == .light ? Color.white : Color.black)
                            .opacity(mediaDetailTopChromeOpacity)
                    )
                    .frame(maxWidth: .infinity, alignment: .top)
                    .offset(y: isUIHidden ? -topChromeHideOffset : 0)
                    .allowsHitTesting(!isUIHidden)

                    Spacer(minLength: 0)
                
                // Bottom action buttons - показываем только если не скрыты
                if !hideActionButtons {
                    HStack(spacing: 24) {
                        // Share / Download: те же ключи `IconView`, что и в storecards (`Shair`, `Download`).
                        Button(action: {
                            shareMedia()
                        }) {
                            IconView("Shair", size: mediaDetailShareIconPointSize, color: AppTheme.Colors.textPrimary)
                                .offset(y: -2)
                                .frame(width: glassButtonSize, height: glassButtonSize)
                                .background(.ultraThinMaterial, in: glassButtonShape)
                        }
                        .appPlainButtonStyle()

                        // Download button
                        Button(action: {
                            downloadMedia()
                        }) {
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if downloadService.isDownloading {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                                            .scaleEffect(0.8)
                                    } else {
                                        IconView("Download", size: mediaDetailBottomCompactIconPointSize, color: AppTheme.Colors.textPrimary)
                                    }
                                }
                                .offset(y: -2)
                                .frame(width: glassButtonSize, height: glassButtonSize)
                                .background(.ultraThinMaterial, in: glassButtonShape)
                            }
                        }
                        .appPlainButtonStyle()
                        .disabled(downloadService.isDownloading)

                        if let customTrailingAction {
                            let trailingIconName = customTrailingActionIcon?(currentMedia) ?? "Star"
                            Button(action: {
                                customTrailingAction(currentMedia)
                            }) {
                                iconImage(
                                    named: trailingIconName,
                                    color: customTrailingActionIconColor?(currentMedia) ?? AppTheme.Colors.textPrimary,
                                    size: mediaDetailBottomCompactIconPointSize
                                )
                                    .offset(y: -2)
                                    .frame(width: glassButtonSize, height: glassButtonSize)
                                    .background(.ultraThinMaterial, in: glassButtonShape)
                            }
                            .appPlainButtonStyle()
                        } else {
                            // Delete button
                            Button(action: {
                                showDeleteConfirmation = true
                            }) {
                                Group {
                                    if deleteService.isDeleting {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                                            .scaleEffect(0.8)
                                    } else {
                                        IconView("Delete", size: 18, color: .red)
                                            .frame(width: 24, height: 24)
                                    }
                                }
                                .frame(width: glassButtonSize, height: glassButtonSize)
                                .background(.ultraThinMaterial, in: glassButtonShape)
                            }
                            .appPlainButtonStyle()
                            .disabled(deleteService.isDeleting)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 34) // Safe area bottom
                    .offset(y: isUIHidden ? bottomControlsHideOffset : 0)
                }
                
                if isEffectReferencePickMode {
                    Button(action: {
                        confirmEffectReferencePick()
                    }) {
                        Text("Выбрать это фото-референс")
                            .font(AppTheme.Typography.cardTitle)
                            .foregroundColor(AppTheme.Colors.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.customPurple)
                            .cornerRadius(12)
                    }
                    .appPlainButtonStyle()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 34) // Safe area bottom
                    .offset(y: isUIHidden ? bottomControlsHideOffset : 0)
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .ignoresSafeArea(edges: .top)
            .zIndex(1)
        }
        .themeAware()
        .onTapGesture {
            // Toggle UI visibility при тапе на экран (с небольшой задержкой для избежания конфликта с double tap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isUIHidden.toggle()
                }
            }
        }
        .alert("delete_confirmation_title".localized, isPresented: $showDeleteConfirmation) {
            Button("cancel".localized, role: .cancel) { }
            Button("delete".localized, role: .destructive) {
                deleteMedia()
            }
        } message: {
            Text("delete_confirmation_message".localized)
        }
        .sheet(isPresented: $showDebugMetaSheet) {
            debugMetaSheetContent(media: currentMedia)
        }
        .onAppear {
            // View setup when appearing
        }
        .edgeSwipeDismiss {
            onDismiss()
        }
    }
    
    // MARK: - Helper Properties
    
    private func placeholderInfo(for media: GeneratedImage) -> (icon: String, text: String, color: Color) {
        switch media.imageURL {
        case "placeholder-portrait":
            return ("person.crop.rectangle", "Portrait", Color.blue.opacity(0.4))
        case "placeholder-square":
            return ("square.on.square", "Square", Color.green.opacity(0.4))
        case "placeholder-landscape":
            return ("rectangle.landscape", "Landscape", Color.orange.opacity(0.4))
        case "placeholder-tall":
            return ("rectangle.portrait", "Tall", Color.purple.opacity(0.4))
        case "placeholder-wide":
            return ("rectangle.fill", "Wide", Color.red.opacity(0.4))
        case "placeholder-video":
            return ("video.fill", "Video", Color.pink.opacity(0.4))
        default:
            return ("photo.fill", "Photo", Color.gray.opacity(0.4))
        }
    }
    
    // MARK: - Services
    @StateObject private var shareService = ShareService()
    @StateObject private var downloadService = DownloadService()
    @StateObject private var deleteService = DeleteService()
    
    // MARK: - Actions
    
    private func shareMedia() {
        print("📤 Share button tapped!")
        shareService.shareGeneratedImage(currentMedia, isProUser: appState.isProUser)
    }
    
    private func downloadMedia() {
        // Скачивание без paywall; для не‑PRO на изображение накладывается ватермарк, видео сохраняется как есть.
        print("⬇️ Download button tapped!")
        downloadService.downloadGeneratedImage(currentMedia, isProUser: appState.isProUser) { success, error in
            if success {
                print("✅ Media downloaded successfully")
                let key = currentMedia.isVideo ? "gallery_video_saved" : "gallery_image_saved"
                NotificationManager.shared.showSuccess(key.localized)
            } else {
                print("❌ Download failed: \(error ?? "Unknown error")")
                NotificationManager.shared.showError(error ?? "error_gallery_save_generic".localized)
            }
        }
    }
    
    private func deleteMedia() {
        print("🗑️ Delete button tapped!")
        deleteService.deleteGeneratedImage(currentMedia, from: appState) { success, error in
            
            if success {
                print("✅ Media deleted successfully")
                
                // Удаляем медиа из локального массива
                updatedAllMedia.removeAll { $0.id == currentMedia.id }
                
                // Проверяем количество оставшихся медиа
                if updatedAllMedia.isEmpty {
                    // Если медиа не осталось - возвращаемся в галерею
                    print("📱 No media left, returning to gallery")
                    onDismiss()
                } else if updatedAllMedia.count == 1 {
                    // Если осталось только одно медиа - показываем его
                    print("📱 Only one media item left, showing it")
                    withAnimation(.easeOut(duration: 0.3)) {
                        currentIndex = 0
                    }
                    isCurrentImageZoomed = false
                    alignInternalIndexToCurrent()
                } else {
                    // Если осталось несколько медиа - переходим к предыдущему или следующему
                    print("📱 Multiple media items left, navigating to next/previous")
                    let newIndex: Int
                    if currentIndex >= updatedAllMedia.count {
                        // Если текущий индекс больше количества изображений, переходим к последнему
                        newIndex = updatedAllMedia.count - 1
                    } else {
                        // Иначе остаемся на том же индексе (массив сдвинулся)
                        newIndex = currentIndex
                    }

                    withAnimation(.easeOut(duration: 0.3)) {
                        currentIndex = newIndex
                    }
                    isCurrentImageZoomed = false
                    alignInternalIndexToCurrent()
                }
            } else {
                print("❌ Delete failed: \(error ?? "Unknown error")")
                NotificationManager.shared.showError(error ?? "error_gallery_delete_generic".localized)
            }
        }
    }

    // MARK: - Debug Meta Sheet

    private func debugMetaSheetContent(media: GeneratedImage) -> some View {
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Для обычного режима показываем только prompt, чтобы не раскрывать технические метаданные.
                    if !appState.isDebugModeEnabled {
                        if let prompt = media.prompt, !prompt.isEmpty {
                            promptRow(prompt)
                        } else {
                            Text("No prompt")
                                .font(.body)
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .padding()
                        }
                    } else if let prompt = media.prompt, !prompt.isEmpty {
                        promptRow(prompt)
                    } else {
                        Text("No metadata")
                            .font(.body)
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .padding()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        showDebugMetaSheet = false
                    }
                }
            }
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(AppTheme.Colors.textSecondary)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func promptRow(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Text("prompt")
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.textSecondary)
                // Копирование prompt ускоряет повторное использование текста в других генерациях.
                Button {
                    UIPasteboard.general.string = prompt
                    NotificationManager.shared.showSuccess("toast_copied".localized)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.primary)
                }
            }

            Text(prompt)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
    
    private func confirmEffectReferencePick() {
        print("🎨 Effect reference picked: \(currentMedia.id)")
        onEffectReferencePicked?(currentMedia)
        // Закрываем экран
        onDismiss()
    }
    
    /// Те же правила разрешения имён, что и `IconView` / storecards (`Star`, `Star Fill`, …) — иначе `Star Fill` уходит в невалидный `Image(systemName:)`.
    @ViewBuilder
    private func iconImage(named: String, color: Color, size: CGFloat) -> some View {
        IconView(named, size: size, color: color)
    }
}

// MARK: - Zoomable Image View
struct ZoomableImageView: View {
    let imageURL: String
    let onZoomChange: (Bool) -> Void
    
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero
    @State private var remoteImage: UIImage?
    @State private var isRemoteLoading = false
    /// true только после неудачной загрузки; до этого показываем спиннер, а не «Image not found» (иначе мелькает ошибка до старта .task).
    @State private var remoteLoadFailed = false

    init(imageURL: String, eagerSyncFromCache: Bool = true, onZoomChange: @escaping (Bool) -> Void) {
        self.imageURL = imageURL
        self.onZoomChange = onZoomChange
        // Первый кадр до .task: только для текущего/соседних слайдов карусели — иначе N × синхронный lookup на main при сотнях элементов.
        if eagerSyncFromCache {
            _remoteImage = State(initialValue: Self.cachedUIImage(for: imageURL))
        } else {
            _remoteImage = State(initialValue: nil)
        }
    }

    /// Синхронно: RAM/диск full + lr_thumb превью Last Results; локальный файл для галереи.
    private static func cachedUIImage(for imageURL: String) -> UIImage? {
        let normalized = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let u = URL(string: normalized) else { return nil }
            let s = u.absoluteString
            if let full = ImageDownloader.shared.getCachedImage(from: s) { return full }
            return ImageDownloader.shared.getCachedLastResultsThumbnail(for: s)
        }
        return UIImage(contentsOfFile: normalized)
    }

    private var normalizedImageURL: String {
        imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var remoteURL: URL? {
        let lower = normalizedImageURL.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        return URL(string: normalizedImageURL)
    }
    
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let remoteURL {
                    if let remoteImage {
                        zoomableImage(Image(uiImage: remoteImage), geometry: geometry)
                    } else if remoteLoadFailed {
                        errorPlaceholder(geometry: geometry)
                            .onTapGesture {
                                loadRemoteImage(from: remoteURL)
                            }
                    } else {
                        loadingPlaceholder(geometry: geometry)
                    }
                } else {
                    // Local image
                    if let uiImage = UIImage(contentsOfFile: normalizedImageURL) {
                        zoomableImage(Image(uiImage: uiImage), geometry: geometry)
                    } else {
                        // Error state
                        errorPlaceholder(geometry: geometry)
                    }
                }
            }
        }
        .onAppear {
            // Reset zoom when view appears
            scale = 1.0
            lastScale = 1.0
            offset = .zero
            lastOffset = .zero
            onZoomChange(false)
        }
        .task(id: normalizedImageURL) {
            guard let remoteURL else { return }
            remoteLoadFailed = false
            // Сначала общий кэш ImageDownloader (RAM + диск) — тот же ключ, что и у downloadImage(url.absoluteString).
            if let cached = ImageDownloader.shared.getCachedImage(from: remoteURL.absoluteString) {
                remoteImage = cached
                isRemoteLoading = false
                return
            }
            // Last Results: сетка уже могла скачать lr_thumb, пока полный файл ещё пишется — показываем превью сразу, без пустого/ошибочного кадра.
            if let gridThumb = ImageDownloader.shared.getCachedLastResultsThumbnail(for: remoteURL.absoluteString) {
                remoteImage = gridThumb
            }
            loadRemoteImage(from: remoteURL)
        }
    }
    
    private func loadingPlaceholder(geometry: GeometryProxy) -> some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
            )
    }
    
    private func errorPlaceholder(geometry: GeometryProxy) -> some View {
        let labelColor = AppTheme.current == .dark ? Color.white : AppTheme.Colors.textPrimary
        let secondaryLabel = AppTheme.current == .dark ? Color.white.opacity(0.85) : AppTheme.Colors.textPrimary.opacity(0.85)
        return Rectangle()
            .fill(Color.red.opacity(0.3))
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundColor(labelColor)
                    Text("Image not found")
                        .font(AppTheme.Typography.body)
                        .foregroundColor(labelColor)
                    Text("Tap to retry")
                        .font(AppTheme.Typography.bodyTertiary)
                        .foregroundColor(secondaryLabel)
                }
            )
    }

    private func loadRemoteImage(from url: URL) {
        let urlString = url.absoluteString
        // Повторная проверка кэша (на случай гонки с фоновой загрузкой превью).
        if let cached = ImageDownloader.shared.getCachedImage(from: urlString) {
            remoteImage = cached
            remoteLoadFailed = false
            isRemoteLoading = false
            return
        }
        guard !isRemoteLoading else { return }
        remoteLoadFailed = false
        isRemoteLoading = true
        // Не обнуляем remoteImage здесь — иначе при повторном запуске task мелькает пусто/ошибка, хотя кэш уже есть.

        ImageDownloader.shared.downloadImage(from: urlString, effectPreviewLogTag: nil) { result in
            DispatchQueue.main.async {
                isRemoteLoading = false
                switch result {
                case .success(let localPath):
                    if let loaded = UIImage(contentsOfFile: localPath) {
                        remoteImage = loaded
                        remoteLoadFailed = false
                    } else if let fallback = ImageDownloader.shared.getCachedLastResultsThumbnail(for: urlString) {
                        remoteImage = fallback
                        remoteLoadFailed = false
                    } else {
                        remoteImage = nil
                        remoteLoadFailed = true
                    }
                case .failure:
                    // Не сбрасываем в «ошибку», если осталось превью с сетки Last Results.
                    if let fallback = ImageDownloader.shared.getCachedLastResultsThumbnail(for: urlString) {
                        remoteImage = fallback
                        remoteLoadFailed = false
                    } else {
                        remoteImage = nil
                        remoteLoadFailed = true
                    }
                }
            }
        }
    }
    
    private func zoomableImage(_ image: Image, geometry: GeometryProxy) -> some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .scaleEffect(scale)
            .offset(offset)
            .clipped() // Обрезаем изображение, чтобы оно не выходило за границы
            .gesture(
                // Zoom gesture
                MagnificationGesture()
                    .onChanged { value in
                        print("🔍 Zoom gesture: scale=\(lastScale * value)")
                        let newScale = lastScale * value
                        scale = min(max(newScale, 1.0), 4.0) // Ограничиваем масштаб
                    }
                    .onEnded { _ in
                        print("🔍 Zoom ended: finalScale=\(scale)")
                        // Limit zoom levels
                        if scale < 1.0 {
                            scale = 1.0
                            offset = .zero
                        } else if scale > 4.0 {
                            scale = 4.0
                        }
                        lastScale = scale
                        
                        // Reset offset if zoomed out completely
                        if scale == 1.0 {
                            offset = .zero
                            lastOffset = .zero
                        }
                        
                        // Ограничиваем смещение при масштабировании
                        constrainOffset(geometry: geometry)
                        
                        // Notify parent about zoom state
                        onZoomChange(scale > 1.0)
                    }
            )
            .simultaneousGesture(
                // Pan gesture - только когда зумлено
                scale > 1.0 ? 
                AnyGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            print("🤏 High priority pan: translation=\(value.translation)")
                            let newOffset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                            offset = newOffset
                        }
                        .onEnded { _ in
                            lastOffset = offset
                            print("🤏 High priority pan ended: offset=\(offset)")
                            // Ограничиваем смещение после пана
                            constrainOffset(geometry: geometry)
                        }
                ) : 
                AnyGesture(
                    DragGesture(minimumDistance: 200)
                        .onChanged { _ in }
                )
            )
            .onTapGesture(count: 2) {
                // Double tap to zoom in/out
                withAnimation(.easeInOut(duration: 0.3)) {
                    if scale == 1.0 {
                        scale = 2.0
                        lastScale = 2.0
                        onZoomChange(true)
                    } else {
                        scale = 1.0
                        lastScale = 1.0
                        offset = .zero
                        lastOffset = .zero
                        onZoomChange(false)
                    }
                }
                
                // Ограничиваем смещение после двойного тапа
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    constrainOffset(geometry: geometry)
                }
            }
    }
    
    // Функция для ограничения смещения, чтобы изображение не убегало за экран
    private func constrainOffset(geometry: GeometryProxy) {
        let imageSize = geometry.size
        let scaledImageSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        
        // Вычисляем максимальное допустимое смещение
        let maxOffsetX = max(0, (scaledImageSize.width - imageSize.width) / 2)
        let maxOffsetY = max(0, (scaledImageSize.height - imageSize.height) / 2)
        
        // Ограничиваем смещение с анимацией
        withAnimation(.easeOut(duration: 0.2)) {
            offset.width = min(max(offset.width, -maxOffsetX), maxOffsetX)
            offset.height = min(max(offset.height, -maxOffsetY), maxOffsetY)
        }
        
        // Обновляем lastOffset
        lastOffset = offset
    }
}

struct MediaDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let sampleMedia = GeneratedMedia(
            id: "sample",
            localPath: "placeholder-portrait",
            createdAt: Date(),
            styleId: 1,
            userPhotoId: "user-1",
            type: .image,
            logoStyleId: nil,
            logoFontId: nil,
            logoColorIds: nil,
            backgroundColorId: nil,
            brandName: nil,
            logoDescription: nil,
            prompt: nil,
            aiModelId: nil,
            paletteId: nil
        )
        
        MediaDetailView(allMedia: [sampleMedia], currentMedia: sampleMedia, hideActionButtons: false, onDismiss: {})
            .environmentObject(AppState())
    }
} 