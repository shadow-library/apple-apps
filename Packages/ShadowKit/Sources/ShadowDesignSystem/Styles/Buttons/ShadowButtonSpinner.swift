import SwiftUI

struct ShadowButtonSpinner: View {
  static let revolution: TimeInterval = 0.8

  let color: Color
  let size: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    #if os(macOS)
      // AppKit's spinner ignores tint and draws for the window appearance, so it vanishes on light fills.
      TimelineView(.animation(paused: reduceMotion)) { context in
        Circle()
          .trim(from: 0, to: 0.75)
          .stroke(color, style: StrokeStyle(lineWidth: max(size / 7, 1.5), lineCap: .round))
          .rotationEffect(reduceMotion ? .zero : Self.angle(at: context.date))
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
    #else
      ProgressView()
        .controlSize(.small)
        .tint(color)
        .accessibilityHidden(true)
    #endif
  }

  static func angle(at date: Date) -> Angle {
    .degrees(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: revolution) / revolution * 360)
  }
}
