import SwiftUI

/// Racing-number plate: queue position as a cream disc with a green number.
/// Deliberately non-adaptive — real number plates don't change with the
/// livery — so these are fixed constants, not asset tokens.
struct RacingNumberDisc: View {
    let number: Int

    private static let cream = Color(red: 255.0 / 255, green: 239.0 / 255, blue: 179.0 / 255)
    private static let racing = Color(red: 1.0 / 255, green: 62.0 / 255, blue: 55.0 / 255)

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Self.racing)
            .frame(width: 22, height: 22)
            .background(Self.cream, in: Circle())
            .overlay(Circle().strokeBorder(Self.racing.opacity(0.25), lineWidth: 1.5))
            .accessibilityLabel("Queue position \(number)")
    }
}
