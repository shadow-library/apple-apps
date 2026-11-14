import ShadowDesignSystem
import SwiftUI

private let stepTitles = ["Premise", "Hero sections", "Chapters", "Publish"].map { Text(verbatim: $0) }
private let longStepTitles = ["Premise", "Describe the hero sections of your first chapter", "Chapter outline", "Review and publish"].map { Text(verbatim: $0) }

private func stepLabel(_ position: ShadowStepsPosition) -> Text {
  Text("Step \(position.number) of \(position.count)")
}

private func stateLabel(_ state: ShadowStepState) -> Text {
  switch state {
  case .completed: Text("Completed")
  case .current: Text("Current step")
  case .upcoming: Text("Not started")
  }
}

private func pageLabel(_ position: ShadowStepsPosition) -> Text {
  Text("Page \(position.number) of \(position.count)")
}

private struct StepsDemo: View {
  @State var step: Int
  var style: ShadowStepsStyle = .bars
  var titles = stepTitles

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      ShadowSteps(current: step, titles: titles, style: style, position: stepLabel, stateLabel: stateLabel)
      #if os(macOS)
        HStack {
          Spacer()
          Button("Back") { step = max(step - 1, 0) }
            .buttonStyle(.shadowBordered)
            .disabled(step == 0)
          Button("Continue") { step = min(step + 1, titles.count - 1) }
            .buttonStyle(.shadowFilled)
            .disabled(step == titles.count - 1)
        }
      #else
        HStack(spacing: Spacing.space3) {
          Button {
            step = max(step - 1, 0)
          } label: {
            Text("Back").frame(maxWidth: .infinity)
          }
          .buttonStyle(.shadowBordered)
          .disabled(step == 0)
          Button {
            step = min(step + 1, titles.count - 1)
          } label: {
            Text("Continue").frame(maxWidth: .infinity)
          }
          .buttonStyle(.shadowFilled)
          .disabled(step == titles.count - 1)
        }
      #endif
    }
    .shadowCard()
  }
}

private struct PageDotsDemo: View {
  @State var page: Int
  var count = 3

  var body: some View {
    VStack(spacing: Spacing.space2) {
      ShadowPageControl(count: count, selection: $page, label: Text("Onboarding pages"), value: pageLabel)
      Text("Page dots for onboarding.")
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
    }
    .frame(maxWidth: .infinity)
    .shadowCard()
  }
}

struct StepsPage: View {
  var body: some View {
    ComponentPage(component: .steps) {
      StateSection(
        "Step bars",
        note:
          "Segments fill in accent up to and including the current step; the rest stay fill-track. The caption names the step. On Mac Back and Continue sit at the bottom right."
      ) {
        StepsDemo(step: 1)
      }
      StateSection("First and last step", note: "Back is disabled on the first step and Continue on the last.") {
        StepsDemo(step: 0)
        StepsDemo(step: 3)
      }
      StateSection(
        "Numbered",
        note: "Wizard steps with check circles for what is done, a filled number for now and an outlined number for what is next. Horizontal in regular width, vertical on iPhone."
      ) {
        StepsDemo(step: 1, style: .numbered)
        StepsDemo(step: 3, style: .numbered)
      }
      StateSection("Long titles", note: "Titles wrap under their circle and never push the steps off screen.") {
        StepsDemo(step: 1, style: .numbered, titles: longStepTitles)
        StepsDemo(step: 1, titles: longStepTitles)
      }
      StateSection(
        "Page dots",
        note: "Only for swipeable pages of equal weight. The current page is text-primary, the rest border-strong. Tapping a dot jumps to it; VoiceOver adjusts it like a slider."
      ) {
        PageDotsDemo(page: 1)
        PageDotsDemo(page: 0, count: 5)
      }
      StateSection("Light and dark") {
        SchemePair {
          VStack(alignment: .leading, spacing: Spacing.space4) {
            ShadowSteps(current: 1, titles: stepTitles, position: stepLabel)
            ShadowSteps(current: 1, titles: stepTitles, style: .numbered, position: stepLabel, stateLabel: stateLabel)
            ShadowPageControl(count: 3, selection: .constant(1), label: Text("Onboarding pages"), value: pageLabel)
              .frame(maxWidth: .infinity)
          }
        }
      }
    }
  }
}
