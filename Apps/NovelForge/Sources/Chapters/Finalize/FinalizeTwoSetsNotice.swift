import ShadowDesignSystem
import SwiftUI

/// The reference finalizes on one server, so it has no counterpart: the native plan's duplicate table (shadow-native-apps-plan.md, "Finalize commit") lets two
/// devices finalize the same chapter apart. The first canon stands; when another device's finalize kept other updates, both sets are listed for the author.
/// New entities the losing finalize created stay in the Story Bible (Reconcile/Canon, G27).
struct FinalizeTwoSetsNotice: View {
  let chapter: Int
  let sets: FinalizePresentation.TwoSets
  var acknowledge: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      ShadowCallout(
        Text("Chapter \(chapter) was finalized on two devices with different updates", tableName: "Finalize"),
        message: Text(
          "The first finalize stands, and its updates are in the Story Bible. The other finalize's updates were not applied, except that new entries it created in the Story Bible stay. Check that the Story Bible holds what you want.",
          tableName: "Finalize"),
        intent: .warning
      ) {
        if let acknowledge {
          Button(action: acknowledge) {
            Text("Got It", tableName: "Finalize")
          }
        }
      }
      FinalizeUpdateList(title: Text("In the Story Bible", tableName: "Finalize"), updates: sets.applied)
      ForEach(sets.others.indices, id: \.self) { index in
        let other = sets.others[index]
        if let updates = other.updates {
          FinalizeUpdateList(title: Text("Kept by the other finalize, not applied", tableName: "Finalize"), updates: updates)
          if !other.exact {
            Text("Its answers changed since, so this is the review it named as it reads now.", tableName: "Finalize")
              .shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
          }
        } else {
          Text("What the other finalize kept can't be read on this device yet.", tableName: "Finalize")
            .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
      }
    }
  }
}

struct FinalizeUpdateList: View {
  let title: Text
  let updates: [FinalizePresentation.Update]

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      title.shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      if updates.isEmpty {
        Text("No updates", tableName: "Finalize").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      ForEach(updates.indices, id: \.self) { index in
        let update = updates[index]
        VStack(alignment: .leading, spacing: Spacing.space1) {
          HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Text(verbatim: update.category).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
            if let claim = update.claim { Text(verbatim: claim).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary) }
          }
          ForEach(update.details.indices, id: \.self) { detail in
            FinalizeDetailLine(detail: update.details[detail])
          }
        }
      }
    }
  }
}
