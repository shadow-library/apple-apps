import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// What an export holds, shown before anything is written, then the restore's progress or why nothing was restored.
struct RestoreConfirmation: View {
  @Bindable var model: RestoreModel

  var body: some View {
    NavigationStack {
      List {
        switch model.stage {
        case .confirming(let preview): PreviewSections(preview: preview)
        case .restoring:
          Section {
            HStack(spacing: Spacing.space3) {
              ProgressView()
              Text("Restoring your records.", tableName: "Data")
            }
          }
        case .failed(let error):
          Section {
            ShadowCallout(Text("Nothing was restored", tableName: "Data"), message: error.text, intent: .warning)
          }
        case .idle, .reading:
          EmptyView()
        }
      }
      .navigationTitle(Text("Restore from an export", tableName: "Data"))
      .shadowScreen(.pushed)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            model.cancel()
          } label: {
            if case .failed = model.stage { Text("Close", tableName: "Data") } else { Text("Cancel", tableName: "Data") }
          }
          .disabled(model.stage == .restoring)
        }
        if case .confirming = model.stage {
          ToolbarItem(placement: .confirmationAction) {
            Button {
              Task { await model.confirm() }
            } label: {
              Text("Restore", tableName: "Data")
            }
          }
        }
      }
    }
    .interactiveDismissDisabled(model.stage == .restoring)
  }
}

private struct PreviewSections: View {
  let preview: MemoirRestorePreview

  var body: some View {
    Section {
      Text(
        "Everything in this export comes back on this device exactly as it was exported, and sync sends it on like anything you write here. The export’s own file is not changed.",
        tableName: "Data"
      )
      .shadowFont(.subheadline)
      ShadowCallout(
        Text("Don’t join the old storage afterwards", tableName: "Data"),
        message: Text(
          "Everything restored is written now. If you later turn sync on to storage that still holds this vault from another device, what you restore here wins over anything changed there after the export was made. Turn sync on to new storage instead.",
          tableName: "Data"),
        intent: .warning, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
      LabeledContent {
        if let generatedAt = preview.generatedAt {
          Text(generatedAt, format: .dateTime.year().month().day().hour().minute())
        } else {
          Text("Unknown", tableName: "Data")
        }
      } label: {
        Text("Exported", tableName: "Data")
      }
      LabeledContent {
        Text(verbatim: preview.appVersion)
      } label: {
        Text("By Memoir", tableName: "Data")
      }
    } header: {
      Text("This export", tableName: "Data")
    }
    Section {
      ForEach(MemoirStoreKind.allCases, id: \.self) { store in
        LabeledContent {
          Text(preview.entries[store] ?? 0, format: .number)
        } label: {
          Text(verbatim: DataCopy.store(store))
        }
      }
      LabeledContent {
        Text(preview.receiptImages, format: .number)
      } label: {
        Text("Receipt images", tableName: "Data")
      }
      if preview.receiptsWithoutImage > 0 {
        LabeledContent {
          Text(preview.receiptsWithoutImage, format: .number)
        } label: {
          VStack(alignment: .leading, spacing: Spacing.space1) {
            Text("Receipts without their image", tableName: "Data")
            Text("The device that exported them did not hold these images, so they stay missing.", tableName: "Data")
              .shadowFont(.footnote)
              .foregroundStyle(ShadowColor.textSecondary)
          }
        }
      }
      LabeledContent {
        Text(preview.weeklyReviews, format: .number)
      } label: {
        Text("Weekly reviews", tableName: "Data")
      }
    } header: {
      Text("What it holds", tableName: "Data")
    }
    VaultContentsSections(load: .loaded(preview.vaultContents))
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    OnboardingRestoreOffer(model: RestoreModel(context: context)).padding(Spacing.space4).shadowTheme()
  }
}
