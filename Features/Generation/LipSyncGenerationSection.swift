import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Проигрывание preview MP3 голоса из API.
@MainActor
final class LipSyncVoicePreviewPlayer: ObservableObject {
    @Published private(set) var playingSpeakerId: String?

    private var player: AVPlayer?

    func togglePreview(for voice: PixVerseVoice) {
        guard let url = voice.previewURL else { return }
        if playingSpeakerId == voice.speakerId {
            stop()
            return
        }
        stop()
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        playingSpeakerId = voice.speakerId
        player?.play()
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }
    }

    func stop() {
        player?.pause()
        player = nil
        playingSpeakerId = nil
    }
}

/// UI lip sync: слот видео, режим lines/upload, голоса, original audio.
struct LipSyncGenerationSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    @Binding var videoLocalPath: String?
    @Binding var videoProviderJobId: String?
    @Binding var inputMode: LipSyncInputMode
    @Binding var linesPrompt: String
    @Binding var selectedSpeakerId: String?
    @Binding var originalAudioEnabled: Bool
    @Binding var audioFileLocalPath: String?
    @Binding var audioFileDisplayName: String?
    @Binding var audioDurationSeconds: Double?

    let panelCornerRadius: CGFloat
    let promptCardCornerRadius: CGFloat
    let photoTileHeight: CGFloat
    let generationMainPanelFill: Color
    let generationMainPanelStroke: Color
    let promptCardFill: Color
    let generationPanelSecondaryFill: Color
    let isJobRunning: Bool

    private let controlPillHeight: CGFloat = 44
    private let voicePreviewControlSize: CGFloat = 32
    private let lipSyncPromptMinHeight: CGFloat = 132

    @State private var voices: [PixVerseVoice] = []
    @State private var isLoadingVoices = false
    @State private var voicesLoadFailed = false
    @State private var voicesDidLoadOnce = false
    @State private var showVoicePanel = false
    @State private var showAudioImporter = false
    @State private var videoPickerItem: PhotosPickerItem?
    @StateObject private var voicePreview = LipSyncVoicePreviewPlayer()

    private var trimmedPrompt: String {
        linesPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var remainingCharacters: Int {
        max(0, LipSyncLimits.maxTextCharacters - linesPrompt.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            mainInputPanel
            lipSyncSettingsChips
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            loadVoicesIfNeeded()
        }
        .onDisappear {
            voicePreview.stop()
        }
        .fileImporter(
            isPresented: $showAudioImporter,
            allowedContentTypes: [.mp3, .wav],
            allowsMultipleSelection: false
        ) { result in
            handleAudioImport(result)
        }
        .onChange(of: videoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadPickedVideo(newItem) }
        }
        .fullScreenCover(isPresented: $showVoicePanel) {
            voicePanelSheet
        }
    }

    /// Промпт / аудио на всю ширину; видео в верхней строке прижато к тому же правому краю.
    private var mainInputPanel: some View {
        let panelShape = RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                inputModeButton
                Spacer(minLength: 0)
                videoSlot
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            inputContentCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(panelShape.fill(generationMainPanelFill))
        .overlay(panelShape.strokeBorder(generationMainPanelStroke, lineWidth: 1))
    }

    @ViewBuilder
    private var inputContentCard: some View {
        Group {
            if inputMode == .lines {
                linesInputCard
            } else {
                audioUploadCard
            }
        }
        .frame(maxWidth: .infinity, minHeight: lipSyncPromptMinHeight, alignment: .topLeading)
    }

    private var videoSlot: some View {
        Group {
            if let path = videoLocalPath, FileManager.default.fileExists(atPath: path) {
                videoPreview(path: path)
            } else {
                PhotosPicker(selection: $videoPickerItem, matching: .videos) {
                    VStack(spacing: 4) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 18, weight: .semibold))
                        Text("generation_lipsync_add_video".localized)
                            .font(AppTheme.Typography.caption.weight(.medium))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .frame(width: photoTileHeight, height: photoTileHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(generationPanelSecondaryFill)
                    )
                }
                .disabled(isJobRunning)
                .appPlainButtonStyle()
            }
        }
    }

    private func videoPreview(path: String) -> some View {
        LipSyncVideoPreviewTile(
            path: path,
            size: photoTileHeight,
            cornerRadius: 14,
            onClear: clearVideo
        )
    }

    /// Голос и original audio — снаружи карточки, как pill'ы Video.
    private var lipSyncSettingsChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 10) {
                if inputMode == .lines {
                    voicePill
                }
                originalAudioPill
            }
        }
    }

    private var shouldShowVoicesLoading: Bool {
        isLoadingVoices || (!voicesDidLoadOnce && !voicesLoadFailed)
    }

    private var voicePill: some View {
        Button {
            loadVoicesIfNeeded()
            showVoicePanel = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(selectedVoiceTitle)
                    .font(AppTheme.Typography.body.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundColor(AppTheme.Colors.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: controlPillHeight)
            .background(AppTheme.Colors.cardBackground, in: Capsule(style: .continuous))
        }
        .appPlainButtonStyle()
        .disabled(isJobRunning)
        .accessibilityLabel(Text("generation_lipsync_voice_panel".localized))
        .accessibilityValue(Text(selectedVoiceTitle))
    }

    private var originalAudioPill: some View {
        Button {
            originalAudioEnabled.toggle()
        } label: {
            HStack(spacing: 10) {
                Text("generation_lipsync_original_audio".localized)
                    .font(AppTheme.Typography.body.weight(.semibold))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Toggle("", isOn: $originalAudioEnabled)
                    .labelsHidden()
                    .toggleStyle(
                        RoundThumbSwitchToggleStyle(
                            onTint: AppTheme.Colors.primary,
                            offTrackTint: themeManager.currentTheme == .dark
                                ? Color.white.opacity(0.22)
                                : Color.black.opacity(0.1)
                        )
                    )
                    .allowsHitTesting(false)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: controlPillHeight)
            .background(AppTheme.Colors.cardBackground, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .appPlainButtonStyle()
        .accessibilityLabel(Text("generation_lipsync_original_audio".localized))
        .accessibilityValue(Text(originalAudioEnabled ? "generation_audio_on".localized : "generation_audio_off".localized))
    }

    private var inputModeButton: some View {
        Menu {
            Button {
                inputMode = .lines
                clearAudioFile()
            } label: {
                Label("generation_lipsync_mode_lines".localized, systemImage: "pencil")
            }
            Button {
                inputMode = .uploadAudio
                selectedSpeakerId = nil
            } label: {
                Label("generation_lipsync_mode_upload".localized, systemImage: "mic.fill")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: inputMode == .lines ? "pencil" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(inputMode == .lines
                     ? "generation_lipsync_mode_lines".localized
                     : "generation_lipsync_mode_upload".localized)
                    .font(AppTheme.Typography.bodySecondary.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(AppTheme.Colors.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: controlPillHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
            )
        }
        .disabled(isJobRunning)
    }

    private var linesInputCard: some View {
        let cardShape = RoundedRectangle(cornerRadius: promptCardCornerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $linesPrompt, axis: .vertical)
                .font(AppTheme.Typography.body)
                .foregroundColor(AppTheme.Colors.textPrimary.opacity(0.92))
                .lineLimit(4...10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onChange(of: linesPrompt) { _, newValue in
                    if newValue.count > LipSyncLimits.maxTextCharacters {
                        linesPrompt = String(newValue.prefix(LipSyncLimits.maxTextCharacters))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if trimmedPrompt.isEmpty {
                        Text("generation_lipsync_lines_placeholder".localized)
                            .font(AppTheme.Typography.body)
                            .foregroundColor(AppTheme.Colors.textPrimary.opacity(0.44))
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Spacer(minLength: 0)
                Text("\(remainingCharacters)")
                    .font(AppTheme.Typography.caption)
                    .foregroundColor(AppTheme.Colors.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardShape.fill(promptCardFill))
    }

    private var audioUploadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let displayName = audioFileDisplayName, audioFileLocalPath != nil {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundColor(AppTheme.Colors.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(AppTheme.Typography.bodySecondary.weight(.semibold))
                            .lineLimit(1)
                        if let duration = audioDurationSeconds {
                            Text("generation_lipsync_audio_duration".localized(with: Int(duration.rounded())))
                                .font(AppTheme.Typography.caption)
                                .foregroundColor(AppTheme.Colors.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        clearAudioFile()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppTheme.Colors.textSecondary)
                    }
                    .appPlainButtonStyle()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: promptCardCornerRadius, style: .continuous)
                        .fill(promptCardFill)
                )
            } else {
                Button {
                    showAudioImporter = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.badge.plus")
                        Text("generation_lipsync_upload_audio".localized)
                            .font(AppTheme.Typography.body.weight(.medium))
                    }
                    .foregroundColor(AppTheme.Colors.textPrimary.opacity(0.92))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: promptCardCornerRadius, style: .continuous)
                            .fill(generationPanelSecondaryFill)
                    )
                }
                .appPlainButtonStyle()
                .disabled(isJobRunning)
            }

            Text("generation_lipsync_audio_hint".localized)
                .font(AppTheme.Typography.caption)
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var voicePanelSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: true) {
                LazyVStack(spacing: 8) {
                    voicePickerRow(
                        title: "generation_lipsync_voice_auto".localized,
                        subtitle: "generation_lipsync_voice_auto_hint".localized,
                        speakerId: nil,
                        previewURL: nil
                    )

                    if shouldShowVoicesLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                            Text("generation_lipsync_voices_loading".localized)
                                .font(AppTheme.Typography.bodySecondary)
                                .foregroundColor(AppTheme.Colors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                    } else if voicesLoadFailed {
                        VStack(spacing: 12) {
                            Text("generation_lipsync_voices_failed".localized)
                                .font(AppTheme.Typography.bodySecondary)
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .multilineTextAlignment(.center)
                            Button("generation_lipsync_voices_retry".localized) {
                                reloadVoices()
                            }
                            .font(AppTheme.Typography.body.weight(.semibold))
                            .foregroundColor(AppTheme.Colors.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else {
                        ForEach(filteredPresetVoices) { voice in
                            voicePickerRow(
                                title: voice.displayName,
                                subtitle: nil,
                                speakerId: voice.speakerId,
                                previewURL: voice.previewURL
                            )
                        }

                        if voicesDidLoadOnce, filteredPresetVoices.isEmpty {
                            Text("generation_lipsync_voices_empty".localized)
                                .font(AppTheme.Typography.bodySecondary)
                                .foregroundColor(AppTheme.Colors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.Colors.background)
            .navigationTitle("generation_lipsync_voice_panel".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.Colors.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done".localized) {
                        showVoicePanel = false
                    }
                    .foregroundColor(AppTheme.Colors.primary)
                }
            }
        }
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .onAppear {
            if !voicesDidLoadOnce {
                loadVoicesIfNeeded(force: true)
            }
        }
        .onDisappear {
            voicePreview.stop()
        }
    }

    /// Пресеты из API без дублей «Auto» — отдельная строка уже есть выше.
    private var filteredPresetVoices: [PixVerseVoice] {
        voices.filter { voice in
            let name = voice.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return name != "auto"
        }
    }

    private func voicePickerRow(title: String, subtitle: String?, speakerId: String?, previewURL: URL?) -> some View {
        let isSelected = selectedSpeakerId == speakerId
        let isPlaying = speakerId != nil && voicePreview.playingSpeakerId == speakerId
        let rowShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let showsPreview = speakerId != nil && previewURL != nil

        return HStack(spacing: 12) {
            Button {
                selectedSpeakerId = speakerId
                showVoicePanel = false
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(AppTheme.Typography.body.weight(isSelected ? .semibold : .regular))
                            .foregroundColor(AppTheme.Colors.textPrimary)
                        if let subtitle {
                            Text(subtitle)
                                .font(AppTheme.Typography.caption)
                                .foregroundColor(AppTheme.Colors.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(AppTheme.Colors.primary)
                    }
                }
                .contentShape(rowShape)
            }
            .buttonStyle(.plain)

            if showsPreview, let speakerId, let previewURL {
                voicePreviewControl(isPlaying: isPlaying) {
                    let voice = PixVerseVoice(speakerId: speakerId, displayName: title, previewURL: previewURL)
                    voicePreview.togglePreview(for: voice)
                }
            } else {
                Color.clear
                    .frame(width: voicePreviewControlSize, height: voicePreviewControlSize)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(rowShape.fill(isSelected ? AppTheme.Colors.cardBackground : generationPanelSecondaryFill.opacity(0.65)))
    }

    /// Круг фиксированного размера: play/stop без скачка layout.
    private func voicePreviewControl(isPlaying: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.primary.opacity(0.18))
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.primary)
            }
            .frame(width: voicePreviewControlSize, height: voicePreviewControlSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isPlaying ? "Stop preview" : "Play preview"))
    }

    private func reloadVoices() {
        voices = []
        voicesLoadFailed = false
        voicesDidLoadOnce = false
        isLoadingVoices = false
        loadVoicesIfNeeded(force: true)
    }

    private var selectedVoiceTitle: String {
        if selectedSpeakerId == nil {
            return "generation_lipsync_voice_auto".localized
        }
        if let id = selectedSpeakerId,
           let voice = voices.first(where: { $0.speakerId == id }) {
            return voice.displayName
        }
        return "generation_lipsync_voice_auto".localized
    }

    private func loadVoicesIfNeeded(force: Bool = false) {
        if isLoadingVoices { return }
        if voicesDidLoadOnce && !force { return }
        isLoadingVoices = true
        voicesLoadFailed = false
        Task {
            do {
                let fetched = try await PixVerseAPIService.shared.fetchLipSyncVoices()
                await MainActor.run {
                    voices = fetched
                    isLoadingVoices = false
                    voicesDidLoadOnce = true
                }
            } catch {
                await MainActor.run {
                    voicesLoadFailed = true
                    isLoadingVoices = false
                    voicesDidLoadOnce = true
                }
            }
        }
    }

    private func clearVideo() {
        videoLocalPath = nil
        videoProviderJobId = nil
        videoPickerItem = nil
    }

    private func clearAudioFile() {
        audioFileLocalPath = nil
        audioFileDisplayName = nil
        audioDurationSeconds = nil
    }

    private func handleAudioImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importAudio(from: url)
        case .failure:
            break
        }
    }

    private func importAudio(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let ext = url.pathExtension.lowercased()
            guard ext == "mp3" || ext == "wav" else {
                NotificationManager.shared.showError(
                    "generation_lipsync_audio_format_error".localized,
                    customDuration: 4,
                    sizing: .fitContent
                )
                return
            }
            let duration = Self.audioDurationSeconds(at: url)
            guard duration > 0 else { return }
            guard duration <= LipSyncLimits.maxAudioSeconds else {
                NotificationManager.shared.showError(
                    "generation_lipsync_audio_too_long".localized,
                    customDuration: 4,
                    sizing: .fitContent
                )
                return
            }

            let dest = try Self.copyToJobInputsDirectory(source: url, preferredExtension: ext)
            audioFileLocalPath = dest
            audioFileDisplayName = url.lastPathComponent
            audioDurationSeconds = duration
        } catch {
            // Ошибку покажет canSubmit / generate validation.
        }
    }

    private func loadPickedVideo(_ item: PhotosPickerItem) async {
        guard let movie = try? await item.loadTransferable(type: LipSyncPickedVideo.self) else { return }
        await MainActor.run {
            videoLocalPath = movie.localPath
            videoProviderJobId = nil
            videoPickerItem = nil
        }
    }

    static func audioDurationSeconds(at url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    static func copyToJobInputsDirectory(source: URL, preferredExtension: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIVideoJobInputs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let dest = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(preferredExtension)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest.path
    }
}

private struct LipSyncVideoPreviewTile: View {
    let path: String
    let size: CGFloat
    let cornerRadius: CGFloat
    let onClear: () -> Void

    @State private var previewImage: UIImage?
    @State private var durationLabel: String?

    var body: some View {
        let tileShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .allowsHitTesting(false)
            } else {
                Color.black.opacity(0.35)
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                    .scaleEffect(0.85)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .clipShape(tileShape)
        .overlay(alignment: .topLeading) {
            Button(action: onClear) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.onPrimaryText)
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
            .appPlainButtonStyle()
            .padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            if let durationLabel {
                Text(durationLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .shadow(color: Color.black.opacity(0.9), radius: 1.5, x: 0, y: 0.5)
                    .padding(.trailing, 5)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
            }
        }
        .task(id: path) {
            previewImage = nil
            durationLabel = nil
            let loaded = await Task.detached(priority: .userInitiated) {
                GeneratedMedia.ensureVideoThumbnail(at: path)
                return (
                    GeneratedMedia.thumbnailPath(forVideoAt: path),
                    GeneratedMedia.galleryStyleVideoDurationLabel(at: path)
                )
            }.value
            previewImage = UIImage(contentsOfFile: loaded.0)
            durationLabel = loaded.1
        }
    }
}

private struct LipSyncPickedVideo: Transferable {
    let localPath: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(URL(fileURLWithPath: video.localPath))
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mp4" : received.file.pathExtension
            let path = try LipSyncGenerationSection.copyToJobInputsDirectory(
                source: received.file,
                preferredExtension: ext
            )
            return LipSyncPickedVideo(localPath: path)
        }
    }
}
