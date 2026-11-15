import ShadowDesignSystem
import SwiftUI

struct ProgressViewPage: View {
  var body: some View {
    ComponentPage(component: .progressView) {
      StateSection("Linear", note: "4pt on iPhone and iPad, 5pt on Mac. fill-track keeps the unfilled range visible; accent fills it and success-solid marks a finished task.") {
        VStack(alignment: .leading, spacing: Spacing.space4) {
          ProgressView(value: 0.62) {
            Text("Uploading cover")
          } currentValueLabel: {
            Text(0.62, format: .percent)
          }
          ProgressView(value: 1) {
            Text("Chapter 42 · read")
          }
          UnlabelledSample {
            ProgressView(value: 0.35).accessibilityLabel("Syncing library")
          }
        }
        .progressViewStyle(.shadowLinear)
        .shadowCard()
      }
      StateSection("Indeterminate", note: "A bar slides along the track when the total is unknown. With Reduce Motion on it holds still and fades instead.") {
        VStack(alignment: .leading, spacing: Spacing.space4) {
          ProgressView { Text("Checking what relies on it") }
          UnlabelledSample {
            ProgressView().accessibilityLabel("Loading chapters")
          }
        }
        .progressViewStyle(.shadowLinear)
        .shadowCard()
      }
      StateSection(
        "Circular",
        note:
          "Determinate rings sit on fill-track in three sizes; the large ring shows its value. The spinner is the native one, for short waits with a label that says what is happening."
      ) {
        VStack(alignment: .leading, spacing: Spacing.space4) {
          HStack(spacing: Spacing.space4) {
            ProgressView(value: 0.62) {
              Text("")
            } currentValueLabel: {
              Text(0.62, format: .percent.precision(.fractionLength(0)))
            }.controlSize(.large)
            ProgressView(value: 0.3).controlSize(.regular)
            ProgressView(value: 1).controlSize(.small)
            ProgressView(value: 0).controlSize(.regular)
          }
          ProgressView { Text("Checking what relies on it") }
            .controlSize(ShadowDensity.current == .compact ? .small : .regular)
          ProgressView(value: 0.62) {
            Text("Uploading cover")
          } currentValueLabel: {
            Text(0.62, format: .percent)
          }
          .controlSize(.small)
        }
        .progressViewStyle(.shadowRing)
        .shadowCard()
      }
      StateSection(
        "Capacity gauge",
        note: "Progress toward a limit such as a budget: the ring shows the value and a title, turns warning from 90% and danger at the limit."
      ) {
        HStack(spacing: Spacing.space4) {
          ShadowCapacityGauge("Synapse budget", value: 41.2, in: 0...60)
          ShadowCapacityGauge("Storage", value: 0.08)
          ShadowCapacityGauge("Seats", value: 25, in: 0...25)
        }
        .shadowCard()
      }
      StateSection("On glass", note: "The track stays visible over a busy background because fill-track is a translucent fill, not a surface.") {
        GlassStage(height: 150, alignment: .center) {
          ProgressView(value: 0.62) {
            Text("Downloading chapters")
          } currentValueLabel: {
            Text(0.62, format: .percent)
          }
          .progressViewStyle(.shadowLinear)
          .padding(Spacing.space4)
          .shadowGlass(.dense, in: .rect(cornerRadius: Radius.panel, style: .continuous))
        }
      }
      StateSection("Disabled") {
        VStack(alignment: .leading, spacing: Spacing.space4) {
          ProgressView(value: 0.62) {
            Text("Uploading cover")
          } currentValueLabel: {
            Text(0.62, format: .percent)
          }
          .progressViewStyle(.shadowLinear)
          ProgressView(value: 0.62).progressViewStyle(.shadowRing).controlSize(.large)
        }
        .disabled(true)
        .shadowCard()
      }
      StateSection(
        "Native default",
        note: "For comparison: the system styles draw a thinner bar in their own track colour and have no success state, which is why Shadow replaces them."
      ) {
        VStack(alignment: .leading, spacing: Spacing.space4) {
          ProgressView(value: 0.62) { Text("Uploading cover") }
          ProgressView(value: 0.62).progressViewStyle(.circular)
        }
        .shadowCard()
      }
      StateSection("Light and dark") {
        SchemePair {
          VStack(alignment: .leading, spacing: Spacing.space3) {
            ProgressView(value: 0.62) {
              Text("Uploading cover")
            } currentValueLabel: {
              Text(0.62, format: .percent)
            }
            .progressViewStyle(.shadowLinear)
            ProgressView(value: 1) { Text("Chapter 42 · read") }
              .progressViewStyle(.shadowLinear)
            HStack(spacing: Spacing.space3) {
              ProgressView(value: 0.62).progressViewStyle(.shadowRing).controlSize(.large)
              ProgressView(value: 0.3).progressViewStyle(.shadowRing)
              ProgressView().progressViewStyle(.shadowRing)
                .controlSize(ShadowDensity.current == .compact ? .small : .regular)
            }
          }
        }
      }
      .shadowColumnSpan(.full)
    }
  }
}

private struct UnlabelledSample<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Text("Without a visible label")
        .shadowFont(.caption)
        .foregroundStyle(ShadowColor.textTertiary)
        .accessibilityHidden(true)
      content
    }
  }
}
