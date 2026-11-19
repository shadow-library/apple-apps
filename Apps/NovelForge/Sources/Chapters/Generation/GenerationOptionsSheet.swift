import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

/// apps/novel-forge-web/src/features/chapters/ChapterList.tsx:176-179 sends `autoFix`; the guidance and the cap are `GenerateBody` (generation.service.ts:276-286).
struct GenerationOptionsSheet: View {
  let kind: GenerationKind
  let chapter: Int
  let onStart: (GenerationOptions) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var guidance = ""
  @State private var autoFix = true
  @State private var maxFixes = GenerationOptions().maxFixes
  @State private var dismissGuard = ShadowDismissGuard()

  static let fixRange = 0...10
  static let guidanceLimit = 2000

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      Text(description, tableName: "Generation").shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Text("Guidance for this run", tableName: "Generation").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
        ShadowTextEditor(text: $guidance, placeholder: Text("Optional", tableName: "Generation"), limit: Self.guidanceLimit, minHeight: 72, maxHeight: 180) { count in
          Text("\(count.count.formatted()) of \(Self.guidanceLimit.formatted())", tableName: "Generation")
        }
      }
      Toggle(isOn: $autoFix) {
        Text("Repair what the checks find", tableName: "Generation")
      }
      if autoFix {
        Stepper(value: $maxFixes, in: Self.fixRange) {
          Text("Repair at most \(maxFixes) times", tableName: "Generation")
        }
      }
    }
    .padding(Spacing.space6)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .shadowSheetHeader(
      title, subtitle: Text("Chapter \(chapter)", tableName: "Generation"), cancel: ShadowSheetCancel(Text("Cancel", tableName: "Generation"), action: requestDismiss),
      confirm: ShadowSheetConfirm(confirmTitle, systemImage: "sparkles", submitShortcut: true) { start() }
    )
    .shadowSheetStyle(.form)
    .shadowDismissGuard(
      $dismissGuard, title: Text("Discard your guidance?", tableName: "Generation"), discardTitle: Text("Discard", tableName: "Generation"),
      keepEditingTitle: Text("Keep Editing", tableName: "Generation"), onDiscard: { dismiss() }
    )
    .onChange(of: guidance, initial: true) { dismissGuard.hasUnsavedChanges = !guidance.allSatisfy(\.isWhitespace) }
  }

  private var title: Text {
    switch kind {
    case .generate: Text("Generate Chapter", tableName: "Generation")
    case .regenerate: Text("Regenerate Chapter", tableName: "Generation")
    }
  }

  private var confirmTitle: Text {
    switch kind {
    case .generate: Text("Generate", tableName: "Generation")
    case .regenerate: Text("Regenerate", tableName: "Generation")
    }
  }

  // RegenerateChapter.tsx:47
  private var description: LocalizedStringKey {
    switch kind {
    case .generate: "Writes the chapter from its plan, then checks it and repairs what the checks find."
    case .regenerate: "Writes the chapter again from its current plan. The current text stays in its versions, and later chapters are marked out of date once the new draft lands."
    }
  }

  private func requestDismiss() {
    if dismissGuard.requestDismiss() { dismiss() }
  }

  private func start() {
    let options = GenerationOptions(guidance: guidance.trimmingCharacters(in: .whitespacesAndNewlines), autoFix: autoFix, maxFixes: autoFix ? maxFixes : 0)
    dismissGuard.discard()
    dismiss()
    onStart(options)
  }
}
