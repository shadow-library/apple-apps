import MemoirCore
import ShadowDesignSystem
import SwiftUI

/// A day's planned minutes on a track twice the soft capacity, so an overload has room to show past the capacity mark (`fixture-provider.ts:65-66,511-520`).
struct QuestLoadBar: View {
  static let trackScale = 2

  let minutes: Int

  private var capacity: Int { DayLoad.softCapacityMinutes }
  private var isOver: Bool { minutes > capacity }
  private var fill: Double { min(1, Double(max(0, minutes)) / Double(capacity * Self.trackScale)) }
  private var mark: Double { 1 / Double(Self.trackScale) }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(ShadowColor.fillTrack)
        Capsule().fill(isOver ? ShadowColor.warningSolid : ShadowColor.accent).frame(width: proxy.size.width * fill)
        Rectangle().fill(ShadowColor.borderStrong).frame(width: 1).offset(x: proxy.size.width * mark)
      }
    }
    .frame(height: Spacing.space2)
    .accessibilityHidden(true)
  }
}
