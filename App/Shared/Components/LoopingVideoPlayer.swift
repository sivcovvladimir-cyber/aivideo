import SwiftUI
import AVKit

struct LoopingVideoPlayer: View {
    let videoName: String
    let videoExtension: String
    
    @State private var player: AVQueuePlayer?
    @State private var videoAspectRatio: CGFloat = 16.0/9.0
    @State private var playerLooper: AVPlayerLooper?
    @State private var currentVideoName: String = ""
    

    
    init(videoName: String, videoExtension: String = "mp4") {
        self.videoName = videoName
        self.videoExtension = videoExtension
    }
    
    var body: some View {
        GeometryReader { geometry in
          //  let maxWidth = min(geometry.size.width, 600)
          //  let calculatedHeight = maxWidth / videoAspectRatio
            
            ZStack {
                VideoPlayer(player: player)
                    .aspectRatio(contentMode: .fill) // Растягиваем с обрезкой
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped() // Обрезаем по границам
                    // Плейсхолдер под первый кадр: не тянем светлый AppTheme — пейвол всегда тёмный слой.
                    .background(Color(red: 0.09, green: 0.10, blue: 0.13))
                    .onAppear {
                        setupPlayer()
                    }
                    .onChange(of: videoName) { _, _ in
                        setupPlayer()
                    }
                    .allowsHitTesting(false) // Отключаем взаимодействие с плеером
            }
            .clipped()
        }
    }
    
    private func setupPlayer() {
        // Если видео не изменилось, не делаем ничего
        if currentVideoName == videoName {
            return
        }
        
        guard let videoURL = Bundle.main.url(forResource: videoName, withExtension: videoExtension) else {
            return
        }
        
        let playerItem = AVPlayerItem(url: videoURL)
        // Локальный файл из Bundle: не ждём `load(.isPlayable)` перед показом — иначе заметная задержка ~0.3–0.6 с до первого кадра.
        if let existingPlayer = player {
            existingPlayer.replaceCurrentItem(with: playerItem)
            playerLooper = AVPlayerLooper(player: existingPlayer, templateItem: playerItem)
        } else {
            let queue = AVQueuePlayer(playerItem: playerItem)
            player = queue
            playerLooper = AVPlayerLooper(player: queue, templateItem: playerItem)
        }
        player?.play()
        currentVideoName = videoName

        Task {
            _ = try? await playerItem.asset.load(.isPlayable)
        }

        let asset = AVAsset(url: videoURL)
        Task {
            let tracks = try? await asset.loadTracks(withMediaType: .video)
            if let track = tracks?.first {
                let size = try? await track.load(.naturalSize)
                if let size = size {
                    await MainActor.run {
                        videoAspectRatio = size.width / size.height
                    }
                }
            }
        }
    }
    
    // MARK: - Static Helper Methods
    
    /// Aspect ratio экрана
    static var screenAspectRatio: CGFloat {
        UIScreen.main.bounds.width / UIScreen.main.bounds.height
    }
    
    /// Рассчитывает высоту фрейма на основе aspect ratio видео
    /// - Parameter videoName: Имя видеофайла
    /// - Returns: Рекомендуемая высота фрейма
    static func calculateFrameHeight(for videoName: String) -> CGFloat {
        let videoAspectRatio = getVideoAspectRatio(for: videoName)
        let aspectRatioRatio = screenAspectRatio / videoAspectRatio
        
        let percentage: CGFloat
        if aspectRatioRatio < 0.75 {
            percentage = 0.75
        } else if aspectRatioRatio > 0.85 {
            percentage = 0.85
        } else {
            percentage = ceil(aspectRatioRatio * 100) / 100
        }
        
        return UIScreen.main.bounds.height * percentage
    }
    

    
    /// Получает aspect ratio видеофайла
    /// - Parameter videoName: Имя видеофайла
    /// - Returns: Aspect ratio видео (по умолчанию 16:9)
    static func getVideoAspectRatio(for videoName: String) -> CGFloat {
        guard let videoURL = Bundle.main.url(forResource: videoName, withExtension: "mp4") else {
            return 16.0/9.0 // Дефолтное значение
        }
        
        // Используем deprecated API для синхронного доступа
        // Эти методы все еще работают в iOS 17.0
        // TODO: Обновить на async API в будущих версиях iOS
        let asset = AVAsset(url: videoURL)
        let tracks = asset.tracks(withMediaType: .video)
        if let track = tracks.first {
            let size = track.naturalSize
            let aspectRatio = size.width / size.height
            return aspectRatio
        }
        
        return 16.0/9.0 // Дефолтное значение
    }
    

    
    /// Принудительно обновляет aspect ratio для видео
    /// - Parameter videoName: Имя видеофайла
    /// - Returns: Обновленный aspect ratio
    static func updateVideoAspectRatio(for videoName: String) -> CGFloat {
        return getVideoAspectRatio(for: videoName)
    }
    

}