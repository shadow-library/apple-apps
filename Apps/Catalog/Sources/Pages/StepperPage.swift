import ShadowDesignSystem
import SwiftUI

struct StepperPage: View {
  @State private var days = 5
  @State private var words = 3000
  @State private var atMax = 7
  @State private var atMin = 1

  var body: some View {
    ComponentPage(component: .stepper) {
      StateSection("Default", note: "The value sits before the stepper in text-secondary with tabular figures, so it never jitters. Units belong in the label.") {
        FormBlock {
          FormSection {
            ShadowStepper("Days a week", value: $days, in: 1...7)
            ShadowStepper("Chapter word-count target", value: $words, in: 500...10_000, step: 500)
          } footer: {
            Text("Choose your weekly writing goal. Missing days are fine.")
          }
        }
      }
      StateSection("Bounds reached", note: "At a bound the end button disables itself instead of silently ignoring the tap.") {
        FormBlock {
          FormSection {
            ShadowStepper("Days a week, at the maximum", value: $atMax, in: 1...7)
            ShadowStepper("Days a week, at the minimum", value: $atMin, in: 1...7)
          }
        }
      }
      StateSection("Disabled") {
        FormBlock {
          FormSection {
            ShadowStepper("Days a week", value: $days, in: 1...7)
              .disabled(true)
          }
        }
      }
    }
  }
}
