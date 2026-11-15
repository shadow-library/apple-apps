import ShadowDesignSystem
import SwiftUI

struct StatisticPage: View {
  var body: some View {
    ComponentPage(component: .statistic) {
      StateSection(
        "Overview", note: "Two-up on iPhone and wider where there is room. A rise in failures is red even though the arrow points up, so the colour says which way is good."
      ) {
        ShadowStatisticGrid {
          ShadowStatistic("Delivered", value: Text("98.4%"), delta: ShadowDeltaBadge(ShadowDelta(change: 0.6, fractionDigits: 1), unit: .suffix("pt")))
          ShadowStatistic("Failed today", value: Text("61"), delta: ShadowDeltaBadge(ShadowDelta(change: 18, higherIsBetter: false)))
          ShadowStatistic("Opened", value: Text("71.2%"), delta: ShadowDeltaBadge(ShadowDelta(change: -1.4, fractionDigits: 1), unit: .suffix("pt")))
          ShadowStatistic("Queued", value: Text("1,204"), delta: ShadowDeltaBadge(ShadowDelta(change: 0)))
        }
      }
      StateSection("Capacity gauge", note: "Progress toward a limit: the ring shows the value and turns warning from 90% and danger at the limit.") {
        ShadowCapacityStatistic("Synapse budget", value: 41.2, in: 0...60, valueText: Text("$41.20 of $60"), caption: Text("Resets 1 December"))
      }
      StateSection("Sparkline and caption", note: "An optional sparkline sits under the value; a caption explains the period.") {
        ShadowStatisticGrid(minimumWidth: 160) {
          ShadowStatistic("Readers", value: Text("3,214"), delta: ShadowDeltaBadge(ShadowDelta(change: 12.5, fractionDigits: 1), unit: .percent), caption: Text("Last 7 days")) {
            ShadowSparkline([12, 14, 13, 18, 17, 22, 26])
          }
          ShadowStatistic("Refunds", value: Text("8"), delta: ShadowDeltaBadge(ShadowDelta(change: -3, higherIsBetter: false)), caption: Text("Last 7 days")) {
            ShadowSparkline([14, 12, 13, 9, 10, 8, 8])
          }
        }
      }
      StateSection(
        "Delta directions",
        note: "Direction and sentiment are independent: the arrow always shows the direction, the colour shows good or bad, and VoiceOver reads the signed change."
      ) {
        ShadowFlowLayout(spacing: Spacing.space3, lineSpacing: Spacing.space3) {
          ShadowDeltaBadge(ShadowDelta(change: 0.6, fractionDigits: 1), unit: .suffix("pt"))
          ShadowDeltaBadge(ShadowDelta(change: -18))
          ShadowDeltaBadge(ShadowDelta(change: 18, higherIsBetter: false))
          ShadowDeltaBadge(ShadowDelta(change: -2.5, higherIsBetter: false, fractionDigits: 1), unit: .percent)
          ShadowDeltaBadge(ShadowDelta(change: 0))
        }
        .shadowCard()
      }
      StateSection("Long values", note: "Large numbers keep tabular figures and shrink before they truncate; labels wrap.") {
        ShadowStatisticGrid(minimumWidth: 160) {
          ShadowStatistic("Chapters read across all novels in your library", value: Text("1,027,331"), delta: ShadowDeltaBadge(ShadowDelta(change: 4_218)))
          ShadowStatistic("Revenue", value: Text("$1,284,903.50"), caption: Text("Since 1 January"))
        }
      }
      StateSection("Light and dark") {
        SchemePair(surface: .app) {
          VStack(spacing: Spacing.space3) {
            ShadowStatistic("Delivered", value: Text("98.4%"), delta: ShadowDeltaBadge(ShadowDelta(change: 0.6, fractionDigits: 1), unit: .suffix("pt")))
            ShadowStatistic("Failed today", value: Text("61"), delta: ShadowDeltaBadge(ShadowDelta(change: 18, higherIsBetter: false)))
            ShadowCapacityStatistic("Synapse budget", value: 41.2, in: 0...60, valueText: Text("$41.20 of $60"), caption: Text("Resets 1 December"))
          }
        }
      }
    }
  }
}
