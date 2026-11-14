import ShadowDesignSystem
import SwiftUI

struct SliderPage: View {
  @State private var brightness = 0.62
  @State private var dragging = 0.34
  @State private var textSize = 2.0
  @State private var volume = 0.0

  var body: some View {
    ComponentPage(component: .slider) {
      StateSection("Continuous", note: "Accent fill over the fill-track colour, with symbols at both ends to show the direction.") {
        FormBlock {
          FormSection {
            symbolSlider("Brightness", value: $brightness, minimum: "sun.min", maximum: "sun.max")
            symbolSlider("Volume, at the minimum", value: $volume, minimum: "speaker", maximum: "speaker.wave.3")
          }
        }
      }
      StateSection("Stepped", note: "Ticks mark the steps. Fewer than four steps belong in a segmented control.") {
        FormBlock {
          FormSection {
            labeled("Text size") {
              Slider(value: $textSize, in: 0...4, step: 1) {
                Text("Text size")
              } minimumValueLabel: {
                Text("A").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
              } maximumValueLabel: {
                Text("A").shadowFont(.title3).foregroundStyle(ShadowColor.textSecondary)
              }
            }
          }
        }
      }
      StateSection("Disabled") {
        FormBlock {
          FormSection {
            symbolSlider("Brightness", value: $dragging, minimum: "sun.min", maximum: "sun.max")
              .disabled(true)
          }
        }
      }
      StateSection("Directly on a card", note: "Outside a form, the slider sits on the card with the same track.") {
        symbolSlider("Brightness", value: $brightness, minimum: "sun.min", maximum: "sun.max")
          .shadowCard()
      }
    }
  }

  private func symbolSlider(_ title: LocalizedStringKey, value: Binding<Double>, minimum: String, maximum: String) -> some View {
    labeled(title) {
      Slider(value: value) {
        Text(title)
      } minimumValueLabel: {
        Image(systemName: minimum).foregroundStyle(ShadowColor.textSecondary).frame(width: Spacing.space6)
      } maximumValueLabel: {
        Image(systemName: maximum).foregroundStyle(ShadowColor.textSecondary).frame(width: Spacing.space6)
      }
    }
  }

  @ViewBuilder
  private func labeled(_ title: LocalizedStringKey, @ViewBuilder slider: () -> some View) -> some View {
    #if os(macOS)
      slider()
    #else
      VStack(alignment: .leading, spacing: Spacing.space1) {
        Text(title).foregroundStyle(ShadowColor.textPrimary)
        slider()
      }
    #endif
  }
}
