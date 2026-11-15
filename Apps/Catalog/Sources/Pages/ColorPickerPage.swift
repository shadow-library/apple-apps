import ShadowDesignSystem
import SwiftUI

struct ColorPickerPage: View {
  enum Swatch: String, CaseIterable, Hashable, Sendable {
    case blue, orange, green, amber, pink, forest, violet
  }

  private static let swatches: [ShadowSwatch<Swatch>] = [
    ShadowSwatch(id: .blue, color: ShadowColor.chart1, label: "Blue"),
    ShadowSwatch(id: .orange, color: ShadowColor.chart2, label: "Orange"),
    ShadowSwatch(id: .green, color: ShadowColor.chart3, label: "Green"),
    ShadowSwatch(id: .amber, color: ShadowColor.chart4, label: "Amber"),
    ShadowSwatch(id: .pink, color: ShadowColor.chart5, label: "Pink"),
    ShadowSwatch(id: .forest, color: ShadowColor.chart6, label: "Forest"),
    ShadowSwatch(id: .violet, color: ShadowColor.chart7, label: "Violet"),
  ]

  @State private var highlight = ShadowColor.accent
  @State private var custom = Color(red: 0.89, green: 0.29, blue: 0.28)
  @State private var swatch = Swatch.violet

  var body: some View {
    ComponentPage(component: .colorPicker) {
      StateSection("System picker", note: "A circular well on iPhone and iPad, a rectangular colour well on Mac. The system picker is the escape hatch.") {
        FormBlock {
          FormSection {
            ColorPicker("Highlight colour", selection: $highlight, supportsOpacity: false)
            ColorPicker("Tag colour", selection: $custom)
          }
        }
      }
      StateSection("Curated swatches", note: "The chart palette comes first so choices stay distinct for colour-blind readers. The current swatch wears a ring, not only a fill.") {
        #if os(macOS)
          FormBlock {
            FormSection { swatches }
          }
        #else
          swatches.shadowCard()
        #endif
      }
      StateSection("Disabled") {
        FormBlock {
          FormSection {
            ColorPicker("Highlight colour", selection: $highlight, supportsOpacity: false)
              .disabled(true)
          }
        }
      }
    }
  }

  private var swatches: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("Highlight colour").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
      ShadowSwatchPicker(selection: $swatch, swatches: Self.swatches)
      Divider()
      ColorPicker(selection: $custom, supportsOpacity: false) {
        Text("More colours…")
          .foregroundStyle(ShadowColor.accentText)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}
