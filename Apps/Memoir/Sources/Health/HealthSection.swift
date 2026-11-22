import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

#if os(iOS)
  import UIKit
#endif

/// Which metrics this device fills from Apple Health, which device reads for the vault, and why this one cannot.
struct HealthSection: View {
  let model: HealthReadingModel

  var body: some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Apple Health", tableName: "Health").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        switch model.availability {
        case .available: metrics
        case .otherPlatform: note(Text("Health data is read on your iPhone or iPad.", tableName: "Health"))
        case .notEntitled: note(Text("This build of Memoir can’t read Apple Health. Type your metrics by hand.", tableName: "Health"))
        case .unavailableOnDevice: note(Text("Health data isn’t available on this device. Type your metrics by hand.", tableName: "Health"))
        case .demo: note(Text("The demo never reads Apple Health. Type your metrics by hand.", tableName: "Health"))
        }
        if let reader = model.otherReader {
          note(Text("\(reader.name) reads Apple Health for this vault.", tableName: "Health"))
        }
        if let failure = model.failure {
          ShadowCallout(Text("Health settings not changed", tableName: "Health"), message: failure.text, intent: .danger)
        }
      }
    }
    .confirmationDialog(
      Text("Read Health on this device instead?", tableName: "Health"),
      isPresented: Binding(get: { model.takeover != nil }, set: { if !$0 { model.cancelTakeover() } }), titleVisibility: .visible, presenting: model.takeover
    ) { _ in
      Button {
        Task { await model.confirmTakeover() }
      } label: {
        Text("Read here instead", tableName: "Health")
      }
      Button(role: .cancel) {
        model.cancelTakeover()
      } label: {
        Text("Cancel", tableName: "Health")
      }
    } message: { takeover in
      Text("\(takeover.current.name) reads Apple Health for this vault. Reading here stops it there; what it already imported stays.", tableName: "Health")
    }
  }

  private var metrics: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Text("Memoir reads, never writes. Turn on a metric to fill its days from Health; your own entries always win.", tableName: "Health")
        .shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
      ForEach(BuiltinMetric.allCases, id: \.self) { metric in
        Toggle(isOn: Binding(get: { model.isReading(metric) }, set: { isOn in Task { await model.set(metric, reading: isOn) } })) {
          Text(verbatim: MetricFormat.name(metric))
        }
        .disabled(model.busy != nil)
      }
      if model.isThisDeviceReader, !model.reading.isEmpty {
        HStack {
          Button {
            Task { await model.importNow() }
          } label: {
            Text("Read Health now", tableName: "Health")
          }
          .buttonStyle(.shadowBordered)
          .disabled(model.isImporting)
          if model.isImporting { ProgressView().controlSize(.small) }
        }
        if case .imported(let report) = model.outcome, !report.failed.isEmpty {
          if report.failed.values.allSatisfy({ $0 == .protectedDataUnavailable }) {
            note(Text("Health can’t be read while the device is locked. Memoir reads it again when you unlock.", tableName: "Health"))
          } else {
            note(Text("Some metrics couldn’t be read from Health. Memoir tries again next time it opens.", tableName: "Health"))
          }
        }
      }
    }
  }

  private func note(_ text: Text) -> some View {
    text.shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
  }
}

/// HealthKit hides a refusal: a metric read from Health with nothing imported may have been refused, so the owner is pointed to the settings and keeps
/// manual entry.
struct HealthNoDataNote: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("No Health data yet", tableName: "Health").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      Text("If you didn’t allow Memoir to read it, change that in Settings. You can still type values here.", tableName: "Health")
        .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
          Button {
            openURL(url)
          } label: {
            Text("Open Health settings", tableName: "Health")
          }
          .buttonStyle(.shadowBordered)
        }
      #endif
    }
  }
}
