import ShadowDesignSystem
import SwiftUI

/// The declared-age gate: the owner confirms they are 18 or older, and only that and the day are kept on this device.
struct AdultConfirmationSheet: View {
  let adult: AdultConfirmationModel
  let confirmed: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Unrestricted writing is for dark or explicit material, so it's only for adults.", tableName: "AgeGate")
        Text("Confirm that you're 18 or older to use it on this device.", tableName: "AgeGate")
        AdultConfirmationText.kept.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.bottom, Spacing.space1)
    }
    .scrollBounceBehavior(.basedOnSize)
    .shadowSheetHeader(
      Text("Confirm Your Age", tableName: "AgeGate"),
      cancel: ShadowSheetCancel(Text("Not Now", tableName: "AgeGate")) { dismiss() },
      confirm: ShadowSheetConfirm(Text("I'm 18 or Older", tableName: "AgeGate")) {
        adult.confirm()
        confirmed()
        dismiss()
      }
    )
    .shadowSheetStyle(.form)
  }
}

enum AdultConfirmationText {
  static let kept = Text(
    "Novel Forge keeps only that you confirmed, and the day, on this device. It never asks for your date of birth, and you can withdraw this at any time in Settings.",
    tableName: "AgeGate")
}

#Preview {
  Color.clear.sheet(isPresented: .constant(true)) {
    AdultConfirmationSheet(
      adult: AdultConfirmationModel(store: AdultConfirmationStore(defaults: UserDefaults(suiteName: "com.shadow.apps.novelforge.preview.age-gate") ?? .standard))
    ) {}
  }
}
