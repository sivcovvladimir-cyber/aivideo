import SwiftUI

struct GenerationProgressOverlayView: View {
    @ObservedObject private var generationJob = GenerationJobService.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Одна строка «описания»: сначала только `generating_tip_1`, через 5 с — по очереди `generating_tip_2`…`generating_tip_7` (без второго абзаца под ними).
    @State private var overlayTipNumber = 1

    /// Заголовок фазы: в dark — `textSecondary` (как вторичный текст в light), в light — `textPrimary`.
    private var overlayTitleColor: Color {
        themeManager.currentTheme == .dark ? AppTheme.Colors.textSecondary : AppTheme.Colors.textPrimary
    }

    private var currentOverlayTip: String {
        "generating_tip_\(overlayTipNumber)".localized
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            // Центр экрана: индикатор и текст; ссылка «в фоне» закреплена у нижнего края (safe area).
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                    .scaleEffect(1.6)

                VStack(spacing: 10) {
                    Text(generationJob.statusTitle)
                        .font(AppTheme.Typography.overlayTitle)
                        .foregroundColor(overlayTitleColor)
                        .multilineTextAlignment(.center)

                    Text(currentOverlayTip)
                        .font(AppTheme.Typography.body)
                        .foregroundColor(AppTheme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .id(overlayTipNumber)
                }
                .padding(.top, 28)

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
        }
        .themeAware()
        .task {
            // 5 с только первая подсказка; дальше та же строка по очереди 2…7 с тем же шагом 5 с.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            var next = 2
            while !Task.isCancelled {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        overlayTipNumber = next
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                next = next == 7 ? 2 : next + 1
            }
        }
    }
}
