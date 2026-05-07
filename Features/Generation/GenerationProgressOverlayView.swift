import SwiftUI

struct GenerationProgressOverlayView: View {
    @ObservedObject private var generationJob = GenerationJobService.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Сначала всегда `generation_overlay_subtitle` (до ~1 минуты), затем `generating_tip_2`…`7` в строках уже выстроены в нужном смысловом порядке.
    private static let sequentialRotatingTipNumbers = Array(2...7)

    @State private var showDurationIntroSubtitle = true
    @State private var sequentialTipIndex = 0

    /// Заголовок фазы: в dark — `textSecondary` (как вторичный текст в light), в light — `textPrimary`.
    private var overlayTitleColor: Color {
        themeManager.currentTheme == .dark ? AppTheme.Colors.textSecondary : AppTheme.Colors.textPrimary
    }

    private var currentOverlayTip: String {
        if showDurationIntroSubtitle {
            return "generation_overlay_subtitle".localized
        }
        guard Self.sequentialRotatingTipNumbers.indices.contains(sequentialTipIndex) else {
            return "generation_overlay_subtitle".localized
        }
        let n = Self.sequentialRotatingTipNumbers[sequentialTipIndex]
        return "generating_tip_\(n)".localized
    }

    /// Смена подсказки анимируется по `id`: старый слой уходит вниз и гаснет, новый заезжает сверху (см. `overlayTipChangeTransition`).
    private var overlayTipIdentity: String {
        showDurationIntroSubtitle ? "intro" : "tip_\(Self.sequentialRotatingTipNumbers[sequentialTipIndex])"
    }

    /// Пружина для смены строк: быстро, без долгого «залипания».
    private static let overlayTipChangeAnimation = Animation.spring(response: 0.4, dampingFraction: 0.88, blendDuration: 0.12)

    private static var overlayTipChangeTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        )
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            GeometryReader { geo in
                // Вертикальная привязка лоадера + заголовка: ~как при центрировании между верхом и кнопкой; подсказка растёт вниз из `frame(minHeight:alignment:.top)`.
                let topContentInset = max(geo.safeAreaInsets.top, 12) + geo.size.height * 0.30

                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: topContentInset)

                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                        .scaleEffect(1.6)

                    Text(generationJob.statusTitle)
                        .font(AppTheme.Typography.overlayTitle)
                        .foregroundColor(overlayTitleColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 28)

                    ZStack(alignment: .top) {
                        Text(currentOverlayTip)
                            .id(overlayTipIdentity)
                            .font(AppTheme.Typography.body)
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.top, 10)
                            .transition(Self.overlayTipChangeTransition)
                    }
                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .top)
                    .clipped()

                    Spacer(minLength: 0)

                    Button {
                        generationJob.continueInBackground()
                    } label: {
                        Text("generation_continue_background".localized)
                            .font(AppTheme.Typography.body)
                            .foregroundColor(AppTheme.contentCircularLoaderTint)
                            .underline()
                            .multilineTextAlignment(.center)
                    }
                    .appPlainButtonStyle()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .themeAware()
        .task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                withAnimation(Self.overlayTipChangeAnimation) {
                    showDurationIntroSubtitle = false
                    sequentialTipIndex = 0
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run {
                    withAnimation(Self.overlayTipChangeAnimation) {
                        sequentialTipIndex = (sequentialTipIndex + 1) % Self.sequentialRotatingTipNumbers.count
                    }
                }
            }
        }
    }
}
