import SwiftUI

// Системный `SwitchToggleStyle` на части версий даёт вытянутый бегунок; здесь — капсула + круглый thumb.
// Располагайте подпись снаружи (`HStack { Text; Toggle("",…) }`): в `makeBody` только дорожка, без `configuration.label`.
// Бегунок через `.position` + `animation(_:value:)`, чтобы и тап, и кастомный `Binding` (например debug PRO) анимировались одинаково.
struct RoundThumbSwitchToggleStyle: ToggleStyle {
    var onTint: Color
    var offTrackTint: Color

    private let trackHeight: CGFloat = 26
    private let horizontalInset: CGFloat = 2

    private var thumbDiameter: CGFloat { trackHeight - horizontalInset * 2 }
    private var trackWidth: CGFloat { thumbDiameter * 2 + horizontalInset * 3 }

    private var thumbCenterXWhenOff: CGFloat { horizontalInset + thumbDiameter / 2 }
    private var thumbCenterXWhenOn: CGFloat { trackWidth - horizontalInset - thumbDiameter / 2 }

    private static var spring: Animation {
        .spring(response: 0.32, dampingFraction: 0.78)
    }

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(configuration.isOn ? onTint : offTrackTint)
                .frame(width: trackWidth, height: trackHeight)

            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.16), radius: 1.2, x: 0, y: 0.6)
                .frame(width: thumbDiameter, height: thumbDiameter)
                .position(
                    x: configuration.isOn ? thumbCenterXWhenOn : thumbCenterXWhenOff,
                    y: trackHeight / 2
                )
        }
        .frame(width: trackWidth, height: trackHeight)
        .animation(Self.spring, value: configuration.isOn)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            configuration.isOn.toggle()
        }
    }
}
