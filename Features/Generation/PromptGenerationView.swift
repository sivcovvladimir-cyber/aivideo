import PhotosUI
import SwiftUI
import UIKit

struct PromptGenerationView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var tokenWallet = TokenWalletService.shared
    @ObservedObject private var generationJob = GenerationJobService.shared
    /// Чтобы сегмент Video/Photo перекрашивался при смене темы (иначе `AppTheme` статичен для SwiftUI).
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var mode: GenerationMode = .video
    @State private var prompt: String = ""
    @State private var durationSeconds: Double = 5
    @State private var audioEnabled = false

    private static let videoDurationChoices = Array(3 ... 7)

    /// Те же строки `aspect_ratio` для фото (`images/create`) и промпт-видео (`videos/create`).
    private enum PhotoAspectRatio: String, CaseIterable {
        case square = "1:1"
        case fourThree = "4:3"
        case threeFour = "3:4"
        case nineSixteen = "9:16"
        case sixteenNine = "16:9"

        /// width / height для мини-превью в пилле.
        var widthOverHeight: CGFloat {
            switch self {
            case .square: return 1
            case .fourThree: return 4.0 / 3.0
            case .threeFour: return 3.0 / 4.0
            case .nineSixteen: return 9.0 / 16.0
            case .sixteenNine: return 16.0 / 9.0
            }
        }
    }

    @State private var photoAspect: PhotoAspectRatio = .nineSixteen
    @State private var videoAspect: PhotoAspectRatio = .nineSixteen
    /// До двух референсов: после persist — только JPEG/PNG для PixVerse (`GenerationJobRequest`: фото `image_path_*`, видео `first_frame_path` / `last_frame_path`).
    @State private var referenceImageSlot0: UIImage?
    @State private var referenceImageSlot1: UIImage?
    @State private var pickerItemSlot0: PhotosPickerItem?
    @State private var pickerItemSlot1: PhotosPickerItem?
    @State private var isLoadingPhoto = false

    private var hasReferencePhotos: Bool {
        referenceImageSlot0 != nil || referenceImageSlot1 != nil
    }
    private let panelCornerRadius: CGFloat = 28
    private let promptCardCornerRadius: CGFloat = 24
    /// Сторона квадратной плитки превью референса; картинка только маскируется в UI (`scaledToFill` + clip), пиксели не кропаются.
    private let photoTileHeight: CGFloat = 160
    /// Единая высота сегмента Video/Photo и пилл настроек — как в референсе Figma.
    private let generationControlPillHeight: CGFloat = 44
    /// Ширина пиллы aspect по самой длинной подписи enum — «9:16» и Audio не смещаются при смене 1:1 ↔ 16:9 и т.д.
    private static let aspectRatioPillMinWidth: CGFloat = {
        let font = AppTheme.Typography.uiFont(weight: .semiBold, size: 16)
        let widest = PhotoAspectRatio.allCases
            .map { ($0.rawValue as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let glyphBox: CGFloat = 26
        let innerSpacing: CGFloat = 10
        let horizontalPadding: CGFloat = 14 * 2
        return ceil(widest) + glyphBox + innerSpacing + horizontalPadding
    }()

    /// Мин. ширина пиллы длительности по всем значениям 3…7 + 2 pt запаса — Audio не дёргается при переключении.
    private static let durationPillMinWidth: CGFloat = {
        let font = AppTheme.Typography.uiFont(weight: .semiBold, size: 16)
        let labels = videoDurationChoices.map { "generation_duration_format".localized(with: $0) }
        let widest = labels
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let horizontalPadding: CGFloat = 16 * 2
        return ceil(widest) + horizontalPadding + 2
    }()

    // «Удиви меня»: яркие сцены, живые герои, знаменитости и культовые персонажи в разных стилях (в т.ч. один карикатурный).
    // Дополнительно — ultra-читабельные «камерные» стили (хром, RGB-сплит, 3D-брутализм) и классические AI-хиты: watercolor, color splash, double exposure, riso, paper-cut и т.п.
    private let surprisePrompts = [
        "Tiny capybara in a tiny raincoat splashing in rainbow puddles, Cartoon-like 3D, supersaturated colors, giggly mood",
        "Grandma on roller skates racing through a candy-colored mall, slow-motion confetti, cheeky comedy vibe, wide lens",
        "Neon fox DJ with headphones at a rooftop party, vaporwave purple and pink lasers, crowd of glowing jellyfish",
        "Street dancer in a chrome mask doing freeze-frame poses, spray-paint halos, fisheye, gritty urban pop energy",
        "Golden retriever puppy as a sushi chef, oversized hat, flying fish that sparkle, anime-meets-realism, cozy chaos",
        "Cyberpunk grandma with holographic tattoos hacking a giant slot machine in Vegas rain, cyan and magenta bloom",
        "Hamster in a race car made of cheese slices, toy commercial lighting, explosive joy, macro cinematic",
        "TikTok-style flash mob: synchronized dancers in neon tracksuits on a beach at blue hour, handheld kinetic camera",
        "Donald Trump as a neon food-truck chef flipping giant tacos, exaggerated political caricature, thick ink outlines, satirical Sunday-comic print look",
        "Snoop Dogg as velvet-roof lowrider BBQ king flipping giant glitter hot dogs in purple haze smoke rings, exaggerated hip-hop caricature, thick ink outlines, satirical Sunday-comic print look, laid-back mischief",
        "Elon Musk in a bronze-age crown launching a toy rocket from a birthday cake, tongue-in-cheek tech-bro parody, warm spotlight, glossy humor",
        "Jeff Bezos on a yacht made of stacked delivery boxes sailing through a sunset of orange and gold, pop-surreal magazine parody, cinematic",
        "Beyoncé in golden wind-machine goddess look on a storm-cloud runway, god-tier lighting, chrome reflections, fierce joy",
        "Freddie Mercury energy: showman in white tank and studded armband on a roaring Wembley-style stage, 80s rock iconography, crowd sea",
        "Michael Jackson in red thriller-era jacket doing a moonwalk through a hall of holographic mirrors, synthwave purple haze",
        "Lady Gaga in avant-garde sculptural dress emerging from a giant cracked egg on the moon, bizarre high-fashion pop, chrome and latex",
        "Bunny in oversized pastel ski goggles at a tropical ski resort party, reggaeton summer palette, fisheye fun",
        "Ariana Grande in oversized pink hoodie on a cloud of candy floss with oversized moon boots, Y2K cute-pop, soft bloom",
        "Hermione Granger mid-spell in a bioluminescent candy forest, wand trail of golden sparks, cinematic fan-poster glow, painterly magic",
        "Daenerys Targaryen with silver hair and flowing cape against a gull-shaped sunset silhouette, epic fantasy oil-painting tableau, windswept",
        "Sherlock Holmes in deerstalker with holographic magnifying glass over neon-noir London rain, stylish detective spoof, teal and magenta",
        "James Bond in razor-pressed tux on a rain-lashed cantilevered glass helipad above a tungsten-noir megacity, copper sodium-vapor haze, fat horizontal anamorphic flares, wet chrome reflections, IMAX-scale luxury espionage one-sheet, fine film grain",
        "Wonder Man in battle armor with golden lasso catching lightning on a stormy cliff, comic splash-page energy, bold primaries",
        "Slider-man in classic red-blue suit swinging through a bioluminescent night carnival, cel-shaded comic motion blur, joyful hero shot",
        "Iron Woman style armored inventor with glowing arc reactor chest piece hovering over a neon city, cinematic MCU energy, lens flare",       
        "Green Ogre and Donkey on a swamp porch eating rainbow waffles, storybook 3D comedy warmth, golden afternoon, silly grin",
        "Eleven from Stranger Things with nosebleed levitating waffles and Christmas lights in a pink 80s bedroom, nostalgic supernatural whimsy",
        "Mischievous raccoon bandit stealing a whole watermelon from a picnic, motion blur, Looney Tunes energy",
        "Yoga flamingo in leg warmers on a lily pad stage, disco ball sun, absurd fitness parody, pop art flat colors",
        "Sloth barista pouring latte art way too slowly, customers are sloths too, deadpan comedy, warm café palette",
        "Dragon made of origami paper unfolding over a city at dawn, soft origami texture, magical realism, awe shot",
    //  "Fashion model drenched in molten liquid chrome on pure black void, mirror-sharp speculars only, Y2K-meets-2025 jewelry macro, single hard strobe, editorial cover",
        "Portrait through bent optical glass, heavy RGB chromatic aberration and magenta-cyan split shadows, Gen-Z music video still, razor digital clarity, trendy glitch-glam",
    //  "Giant inflatable pastel Memphis squiggle sofa in raw concrete Brutalist hall, soft SSS plastic 3D render, oversaturated yet matte, design-magazine hero shot, soft bounce light",
        "Red fox napping on a mossy log in autumn forest, dreamy loose watercolor on cold-press paper, wet-on-wet blooms, granulating pigments, deckled edges, soft natural light",
    //  "Lone dancer in crimson silk twirling in a rain-soaked noir alley, world in desaturated charcoal gray except the dress and umbrella in explosive color splash, cinematic shallow depth",
    //  "Silhouette of a wolf howling merged with aurora borealis and pine treeline, poetic double exposure on matte midnight blue, ethereal glow, editorial wildlife poster",
    //  "Retro still life of citrus and vases, risograph print texture, limited soy-ink palette mint and coral, misregistered layers, visible grain, trendy zine aesthetic",
    //  "Layered paper-cut diorama of a tiny neon city at night, kirigami depth shadows, backlit vellum windows, tactile craft macro, stop-motion storybook vibe",
    //  "Single crane over misty mountains in minimal sumi-e ink wash, vast negative space, one vermillion seal stamp accent, meditative traditional-meets-AI calm",
    //  "Macro splash of pearlescent paint colliding in mid-air, slow-mo liquid ribbons, color gel lighting, ASMR satisfying gloss, ultra-clean studio backdrop",
    ]

    private enum GenerationMode: String, CaseIterable, Identifiable {
        case video
        case photo

        var id: String { rawValue }

        var title: String {
            switch self {
            case .video: return "generation_mode_video".localized
            case .photo: return "generation_mode_photo".localized
            }
        }
    }

    private var cost: Int {
        let calculator = GenerationCostCalculator()
        switch mode {
        case .video:
            return calculator.promptGenerationCost(
                kind: .video(durationSeconds: Int(durationSeconds.rounded()), audioEnabled: audioEnabled)
            )
        case .photo:
            return calculator.promptGenerationCost(kind: .photo)
        }
    }

    private var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canGenerate: Bool {
        canSubmit && !generationJob.isRunning
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TopNavigationBar(
                    title: "generation_screen_title".localized,
                    showBackButton: true,
                    customRightContent: AnyView(
                        ProStatusBadge(
                            tokenBalance: tokenWallet.balance,
                            action: { appState.presentPaywallFullscreen() }
                        )
                    ),
                    backgroundColor: AppTheme.Colors.background,
                    onBackTap: {
                        appState.currentScreen = .effectsHome
                    }
                )

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        generationModeSection
                        generationMainCard

                        if mode == .video {
                            videoSettingsSection
                        } else if !hasReferencePhotos {
                            // Пилла aspect только без референса; с фото `aspect_ratio` в API не шлём — дефолт useapi/PixVerse `auto` по входному изображению.
                            photoSettingsSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // Кнопка закреплена над home indicator; контент скролла получает нижний inset автоматически.
                    bottomGenerateBar
                }
            }
            .onAppear {
                applyGenerationScreenDraft(appState.generationPromptScreenDraft)
            }
            .onDisappear {
                appState.replaceGenerationPromptScreenDraft(collectGenerationScreenDraft())
            }
            .background(AppTheme.Colors.background.ignoresSafeArea())
            .themeAware()
            .themeAnimation()
        }
        .onChange(of: pickerItemSlot0) { _, newItem in
            guard let newItem else { return }
            Task { await loadPickerItem(newItem, slot: 0) }
        }
        .onChange(of: pickerItemSlot1) { _, newItem in
            guard let newItem else { return }
            Task { await loadPickerItem(newItem, slot: 1) }
        }
    }

    // Переключатель режимов вынесен в отдельный блок над карточкой промпта и использует явный active/inactive контраст.
    private var generationModeSection: some View {
        modePicker
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.Colors.cardBackground.opacity(0.92))
            )
    }

    private var modePicker: some View {
        let isDark = themeManager.currentTheme == .dark
        // Светлая тема: «таб» почти белый — подпись должна быть тёмной, иначе как сейчас (белое на белом).
        let selectedSegmentForeground: Color = isDark ? .white : AppTheme.Colors.textPrimary
        let selectedSegmentFill: Color = isDark ? Color.white.opacity(0.16) : Color.white

        return HStack(spacing: 4) {
            ForEach(GenerationMode.allCases) { item in
                let isSelected = mode == item
                Button {
                    mode = item
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item == .video ? "video" : "camera")
                            .font(.system(size: 13, weight: .semibold))
                        Text(item.title)
                            .font(AppTheme.Typography.bodySecondary.weight(.medium))
                    }
                    .foregroundColor(isSelected ? selectedSegmentForeground : AppTheme.Colors.textSecondary.opacity(0.88))
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .frame(height: generationControlPillHeight - 6)
                    // Прозрачная зона сегмента тоже должна ловить тап — иначе срабатывает только по тексту/иконке.
                    .contentShape(Capsule(style: .continuous))
                    .background(
                        Capsule(style: .continuous)
                            .fill(isSelected ? selectedSegmentFill : Color.clear)
                    )
                }
                .frame(maxWidth: .infinity)
                .appPlainButtonStyle()
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .frame(height: generationControlPillHeight)
        .background(
            Capsule(style: .continuous)
                .fill(AppTheme.Colors.background.opacity(0.38))
        )
    }

    private var generationMainCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            promptCard
            inputPhotoSection
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .fill(AppTheme.Colors.cardBackground.opacity(0.9))
        )
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            promptSection
            promptActionsRow
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: promptCardCornerRadius, style: .continuous)
                .fill(AppTheme.Colors.background.opacity(0.32))
        )
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("generation_prompt_title".localized)
                .font(AppTheme.Typography.subtitle)
                .foregroundColor(AppTheme.Colors.textPrimary)

            TextEditor(text: $prompt)
                .font(AppTheme.Typography.body)
                .foregroundColor(AppTheme.Colors.textPrimary.opacity(0.92))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110)
                .padding(.horizontal, 2)
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("generation_prompt_placeholder".localized)
                            .font(AppTheme.Typography.body)
                            .foregroundColor(AppTheme.Colors.textPrimary.opacity(0.44))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // Нижняя строка карточки повторяет сценарий Figma: быстро очистить текст или получить случайный промпт в один тап.
    private var promptActionsRow: some View {
        HStack(spacing: 10) {
            Button {
                prompt = ""
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red.opacity(prompt.isEmpty ? 0.45 : 0.92))
                    .frame(width: 34, height: 34)
                    .background(AppTheme.Colors.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .appPlainButtonStyle()
            .disabled(prompt.isEmpty)
            .accessibilityLabel(Text(verbatim: "Clear prompt"))

            Spacer(minLength: 0)

            Button {
                applySurprisePrompt()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                    Text("surprise_me".localized)
                        .font(AppTheme.Typography.bodySecondary.weight(.semibold))
                }
                .foregroundColor(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AppTheme.Colors.background.opacity(0.42), in: Capsule())
            }
            .appPlainButtonStyle()
            .disabled(generationJob.isRunning)
        }
    }

    /// Соотношение сторон выходного изображения: пилла по кругу + мини-силуэт, значение уходит в PixVerse `aspect_ratio`.
    private var photoSettingsSection: some View {
        HStack(spacing: 10) {
            photoAspectPill
            Spacer(minLength: 0)
        }
    }

    private var photoAspectPill: some View {
        Button {
            cyclePhotoAspect()
        } label: {
            HStack(spacing: 10) {
                PhotoAspectRatioGlyph(widthOverHeight: photoAspect.widthOverHeight)
                Text(photoAspect.rawValue)
                    .font(AppTheme.Typography.body.weight(.semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: Self.aspectRatioPillMinWidth)
            .frame(height: generationControlPillHeight)
            .background(AppTheme.Colors.cardBackground, in: Capsule(style: .continuous))
        }
        .appPlainButtonStyle()
        .accessibilityLabel(Text("generation_photo_settings_title".localized))
        .accessibilityValue(Text(photoAspect.rawValue))
    }

    private func cyclePhotoAspect() {
        let all = PhotoAspectRatio.allCases
        guard let i = all.firstIndex(of: photoAspect) else { return }
        photoAspect = all[(i + 1) % all.count]
    }

    private func applySurprisePrompt() {
        guard let nextPrompt = surprisePrompts.randomElement() else { return }
        prompt = nextPrompt
    }

    private func cycleVideoAspect() {
        let all = PhotoAspectRatio.allCases
        guard let i = all.firstIndex(of: videoAspect) else { return }
        videoAspect = all[(i + 1) % all.count]
    }

    private var videoAspectPill: some View {
        Button {
            cycleVideoAspect()
        } label: {
            HStack(spacing: 10) {
                PhotoAspectRatioGlyph(widthOverHeight: videoAspect.widthOverHeight)
                Text(videoAspect.rawValue)
                    .font(AppTheme.Typography.body.weight(.semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: Self.aspectRatioPillMinWidth)
            .frame(height: generationControlPillHeight)
            .background(AppTheme.Colors.cardBackground, in: Capsule(style: .continuous))
        }
        .appPlainButtonStyle()
        .accessibilityLabel(Text("generation_video_aspect_accessibility".localized))
        .accessibilityValue(Text(videoAspect.rawValue))
    }

    /// Ряд настроек видео повторяет макет: aspect ratio первым, затем длительность; audio — через встроенный switch.
    private var videoSettingsSection: some View {
        HStack(alignment: .center, spacing: 10) {
            if !hasReferencePhotos {
                videoAspectPill
            }
            videoDurationPill
            videoAudioPill
            Spacer(minLength: 0)
        }
    }

    private var videoDurationPill: some View {
        Button {
            cycleVideoDuration()
        } label: {
            Text("generation_duration_format".localized(with: Int(durationSeconds.rounded())))
                .font(AppTheme.Typography.body.weight(.semibold))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .padding(.horizontal, 16)
                .frame(minWidth: Self.durationPillMinWidth)
                .frame(height: generationControlPillHeight)
                .background(AppTheme.Colors.cardBackground, in: Capsule(style: .continuous))
        }
        .appPlainButtonStyle()
        .accessibilityLabel(Text("generation_duration_title".localized))
        .accessibilityValue(Text("generation_duration_format".localized(with: Int(durationSeconds.rounded()))))
    }

    /// Следующее значение длительности по кругу после максимума (как барабан без отдельного шита).
    private func cycleVideoDuration() {
        let choices = Self.videoDurationChoices
        let current = Int(durationSeconds.rounded())
        guard let index = choices.firstIndex(of: current) else {
            durationSeconds = Double(choices.first ?? 5)
            return
        }
        let next = choices[(index + 1) % choices.count]
        durationSeconds = Double(next)
    }

    private var videoAudioPill: some View {
        HStack(spacing: 10) {
            Text("generation_audio_title".localized)
                .font(AppTheme.Typography.body.weight(.semibold))
                .foregroundColor(AppTheme.Colors.textPrimary)

            Toggle("", isOn: $audioEnabled)
                .labelsHidden()
                .toggleStyle(
                    RoundThumbSwitchToggleStyle(
                        onTint: AppTheme.Colors.primary,
                        offTrackTint: themeManager.currentTheme == .dark
                            ? Color.white.opacity(0.22)
                            : Color.black.opacity(0.1)
                    )
                )
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: generationControlPillHeight)
        .background(AppTheme.Colors.cardBackground, in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("generation_audio_title".localized))
        .accessibilityValue(Text(audioEnabled ? "generation_audio_on".localized : "generation_audio_off".localized))
    }

    private var inputPhotoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let img0 = referenceImageSlot0, let img1 = referenceImageSlot1 {
                HStack(spacing: 10) {
                    referenceImagePreview(image: img0, slot: 0)
                    referenceImagePreview(image: img1, slot: 1)
                }
            } else if let img0 = referenceImageSlot0 {
                HStack(spacing: 10) {
                    referenceImagePreview(image: img0, slot: 0)
                    secondReferenceUploadTile
                }
            } else {
                PhotosPicker(selection: $pickerItemSlot0, matching: .images) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                        Text(isLoadingPhoto ? "loading".localized : "upload_photo".localized)
                            .font(AppTheme.Typography.body.weight(.medium))
                    }
                    .foregroundColor(AppTheme.Colors.textPrimary.opacity(0.92))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppTheme.Colors.background.opacity(0.52))
                    )
                }
                .disabled(isLoadingPhoto)
                .appPlainButtonStyle()
            }
        }
    }

    /// Вторая плитка «загрузить» — только когда первый слот уже занят (макс. 2 референса).
    private var secondReferenceUploadTile: some View {
        PhotosPicker(selection: $pickerItemSlot1, matching: .images) {
            VStack(spacing: 8) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 18, weight: .semibold))
                Text(isLoadingPhoto ? "loading".localized : "upload_photo".localized)
                    .font(AppTheme.Typography.body.weight(.medium))
            }
            .foregroundColor(AppTheme.Colors.textPrimary)
            .frame(width: photoTileHeight, height: photoTileHeight)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.Colors.background.opacity(0.52))
            )
        }
        .disabled(isLoadingPhoto)
        .appPlainButtonStyle()
    }

    private func referenceImagePreview(image: UIImage, slot: Int) -> some View {
        // Оверлей не должен жить в `HStack` со `Spacer`: внешний `HStack` даёт колонке maxWidth — иконка «обновить» уезжала за пределы 160×160.
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: photoTileHeight, height: photoTileHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topLeading) {
                Button {
                    clearReferenceSlot(slot)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.onPrimaryText)
                        .frame(width: 24, height: 24)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .appPlainButtonStyle()
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                Group {
                    if slot == 0 {
                        PhotosPicker(selection: $pickerItemSlot0, matching: .images) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.onPrimaryText)
                                .frame(width: 24, height: 24)
                                .background(Color.black.opacity(0.55), in: Circle())
                        }
                        .disabled(isLoadingPhoto)
                    } else {
                        PhotosPicker(selection: $pickerItemSlot1, matching: .images) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(AppTheme.Colors.onPrimaryText)
                                .frame(width: 24, height: 24)
                                .background(Color.black.opacity(0.55), in: Circle())
                        }
                        .disabled(isLoadingPhoto)
                    }
                }
                .padding(8)
            }
    }

    private func clearReferenceSlot(_ slot: Int) {
        if slot == 0 {
            referenceImageSlot0 = referenceImageSlot1
            referenceImageSlot1 = nil
        } else {
            referenceImageSlot1 = nil
        }
        pickerItemSlot0 = nil
        pickerItemSlot1 = nil
    }

    private var bottomGenerateBar: some View {
        // Кнопка должна выглядеть явно disabled, когда генерацию нельзя стартовать с текущего экрана.
        let enabled = canGenerate
        return VStack(spacing: 0) {
            Button {
                handleGenerateTap()
            } label: {
                PrimaryGenerationButtonLabel(
                    title: "generate".localized,
                    tokenCost: cost,
                    isEnabled: enabled
                )
            }
            .appPlainButtonStyle()
            .disabled(!enabled)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(
            AppTheme.Colors.background
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// Снимок полей экрана в `AppState`, чтобы при смене таба и возврате не сбрасывались режим, промпт, пиллы и превью референса.
    private func collectGenerationScreenDraft() -> GenerationPromptScreenDraft {
        let ref0 = referenceImageSlot0.flatMap { image in
            image.downscaled(maxLongSide: 1600).jpegData(compressionQuality: 0.82)
        }
        let ref1 = referenceImageSlot1.flatMap { image in
            image.downscaled(maxLongSide: 1600).jpegData(compressionQuality: 0.82)
        }
        return GenerationPromptScreenDraft(
            modeRaw: mode.rawValue,
            prompt: prompt,
            durationSeconds: normalizedDurationSeconds(durationSeconds),
            audioEnabled: audioEnabled,
            photoAspectRaw: photoAspect.rawValue,
            videoAspectRaw: videoAspect.rawValue,
            referenceImageJPEGData: ref0,
            referenceImage2JPEGData: ref1
        )
    }

    private func applyGenerationScreenDraft(_ draft: GenerationPromptScreenDraft) {
        mode = GenerationMode(rawValue: draft.modeRaw) ?? .video
        prompt = draft.prompt
        durationSeconds = normalizedDurationSeconds(draft.durationSeconds)
        audioEnabled = draft.audioEnabled
        photoAspect = PhotoAspectRatio(rawValue: draft.photoAspectRaw) ?? .nineSixteen
        videoAspect = PhotoAspectRatio(rawValue: draft.videoAspectRaw) ?? .nineSixteen
        pickerItemSlot0 = nil
        pickerItemSlot1 = nil
        referenceImageSlot0 = draft.referenceImageJPEGData.flatMap { UIImage(data: $0) }
        referenceImageSlot1 = draft.referenceImage2JPEGData.flatMap { UIImage(data: $0) }
    }

    private func normalizedDurationSeconds(_ seconds: Double) -> Double {
        let choices = Self.videoDurationChoices
        let rounded = Int(seconds.rounded())
        if choices.contains(rounded) { return Double(rounded) }
        return Double(choices.min(by: { abs($0 - rounded) < abs($1 - rounded) }) ?? 5)
    }

    private func handleGenerateTap() {
        guard canGenerate else { return }

        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var firstPath: String?
        var secondPath: String?
        do {
            if let img0 = referenceImageSlot0 {
                firstPath = try generationJob.persistInputImage(img0)
            }
            if let img1 = referenceImageSlot1 {
                secondPath = try generationJob.persistInputImage(img1)
            }
        } catch {
            appState.notificationManager.showError(error.localizedDescription, customDuration: 5, sizing: .fitContent)
            return
        }

        let anyReference = firstPath != nil || secondPath != nil
        // При старте генерации показывается fullscreen-оверлей: закрываем клавиатуру,
        // чтобы не оставлять её поверх экрана и не создавать визуальный конфликт.
        dismissKeyboard()

        switch mode {
        case .video:
            generationJob.start(
                request: .promptVideo(
                    prompt: normalizedPrompt,
                    duration: Int(durationSeconds.rounded()),
                    audioEnabled: audioEnabled,
                    aspectRatio: anyReference ? nil : videoAspect.rawValue,
                    inputImagePath: firstPath,
                    secondInputImagePath: secondPath
                ),
                cost: cost
            )
        case .photo:
            generationJob.start(
                request: .promptPhoto(
                    prompt: normalizedPrompt,
                    aspectRatio: anyReference ? nil : photoAspect.rawValue,
                    inputImagePath: firstPath,
                    secondInputImagePath: secondPath
                ),
                cost: cost
            )
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    @MainActor
    private func loadPickerItem(_ item: PhotosPickerItem, slot: Int) async {
        isLoadingPhoto = true
        defer {
            isLoadingPhoto = false
            if slot == 0 {
                pickerItemSlot0 = nil
            } else {
                pickerItemSlot1 = nil
            }
        }

        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage.decodedForAPIUpload(from: data) {
                if slot == 0 {
                    referenceImageSlot0 = image
                } else {
                    referenceImageSlot1 = image
                }
            }
        } catch {
            appState.notificationManager.showError(error.localizedDescription, customDuration: 5, sizing: .fitContent)
        }
    }
}

// MARK: - Мини-превью соотношения сторон в пилле (не размер выхода API, только наглядность).

private struct PhotoAspectRatioGlyph: View {
    let widthOverHeight: CGFloat
    private let box: CGFloat = 26

    var body: some View {
        let woh = max(0.2, min(widthOverHeight, 6))
        let (w, h): (CGFloat, CGFloat) = {
            if woh >= 1 {
                return (box, box / woh)
            }
            return (box * woh, box)
        }()

        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(AppTheme.Colors.textPrimary.opacity(0.85), lineWidth: 1.5)
            .frame(width: w, height: h)
            .frame(width: box, height: box)
    }
}
