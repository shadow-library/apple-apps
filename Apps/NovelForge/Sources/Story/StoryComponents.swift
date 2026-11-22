import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct StoryLoaded<Content: View>: View {
  let model: StoryModel
  @ViewBuilder let content: (StoryStructure) -> Content

  var body: some View {
    switch model.structure {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error):
      ShadowContentUnavailable(Text("The story could not be read", tableName: "Story"), systemImage: "exclamationmark.triangle", message: error.text) {
        Button {
          model.retry()
        } label: {
          Text("Try Again", tableName: "Story")
        }
      }
      .fillingSurface()
    case .loaded(let structure):
      content(structure)
    }
  }
}

struct StoryUnavailable: View {
  let reason: String

  init(faults: [ReadFault]) {
    reason = faults.first?.message ?? ""
  }

  var body: some View {
    ShadowContentUnavailable(
      Text("Unavailable", tableName: "Story"), kind: .error, systemImage: "exclamationmark.triangle",
      message: Text("This part of the story is not up to date on this device yet.", tableName: "Story")
    )
    .help(Text(verbatim: reason))
    .fillingSurface()
  }
}

struct StoryNotFound: View {
  let title: Text

  var body: some View {
    ShadowContentUnavailable(title, systemImage: "questionmark.folder", message: Text("It may have been removed on this or another device.", tableName: "Story"))
      .fillingSurface()
  }
}

struct RemovedItemsSection: View {
  let model: StoryModel
  let items: [RemovedStoryItem]

  var body: some View {
    if model.removedIsUnavailable {
      Section {
        Label(title: { Text("Removed items are not up to date on this device yet.", tableName: "Story") }, icon: { Image(systemName: "exclamationmark.triangle") })
          .shadowFont(.footnote).foregroundStyle(ShadowColor.warningText)
      } header: {
        ShadowSectionHeader(Text("Recently removed", tableName: "Story"))
      }
    } else if !items.isEmpty {
      Section {
        ForEach(items) { item in
          ShadowListRow(
            title: Text(verbatim: item.name), caption: Text("Removed", tableName: "Story"), leading: { Image(systemName: "trash").foregroundStyle(ShadowColor.textTertiary) },
            trailing: {
              Button {
                Task { await model.restore(item) }
              } label: {
                Text("Restore", tableName: "Story")
              }
            })
        }
      } header: {
        ShadowSectionHeader(Text("Recently removed", tableName: "Story"))
      }
    }
  }
}

struct StoryFormScaffold<Content: View>: View {
  let heading: LocalizedStringResource
  let confirmTitle: Text
  let canSubmit: Bool
  let hasChanges: Bool
  let submit: () async throws -> Void
  @ViewBuilder let content: Content
  @State private var dismissGuard = ShadowDismissGuard()
  @State private var isSubmitting = false
  @State private var error: PresentedError?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        if let error { ShadowValidationMessage(error.text) }
        content
      }
      .padding(.bottom, Spacing.space1)
      .disabled(isSubmitting)
    }
    .scrollBounceBehavior(.basedOnSize)
    .shadowSheetHeader(
      Text(heading), cancel: ShadowSheetCancel(Text("Cancel", tableName: "Story"), isDisabled: isSubmitting, action: requestDismiss),
      confirm: ShadowSheetConfirm(confirmTitle, isDisabled: !canSubmit || isSubmitting, submitShortcut: true) { Task { await perform() } }
    )
    .shadowSheetStyle(.form)
    .shadowDismissGuard(
      $dismissGuard, title: Text("Discard your changes?", tableName: "Story"), discardTitle: Text("Discard", tableName: "Story"),
      keepEditingTitle: Text("Keep Editing", tableName: "Story"), onDiscard: { dismiss() }
    )
    .onChange(of: hasChanges, initial: true) { dismissGuard.hasUnsavedChanges = hasChanges }
    .onChange(of: isSubmitting) { dismissGuard.isBusy = isSubmitting }
  }

  private func requestDismiss() {
    if dismissGuard.requestDismiss() { dismiss() }
  }

  private func perform() async {
    guard canSubmit, !isSubmitting else { return }
    isSubmitting = true
    error = nil
    defer { isSubmitting = false }
    do {
      try await submit()
      dismiss()
    } catch {
      self.error = PresentedError(error, known: StoryErrors.headline)
    }
  }
}

struct StoryField<Field: View>: View {
  let label: Text
  let hint: Text?
  @ViewBuilder let field: Field

  init(_ label: Text, hint: Text? = nil, @ViewBuilder field: () -> Field) {
    self.label = label
    self.hint = hint
    self.field = field()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      label.shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      field
      if let hint { hint.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary) }
    }
  }
}

enum StoryKey {
  static func slug(_ text: String) -> String {
    let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
    return words.joined(separator: "-")
  }

  static func isValid(_ key: String) -> Bool {
    !key.isEmpty && !key.contains { $0.isWhitespace }
  }

  static func unused(prefix: String, taken: [String]) -> String {
    var number = taken.count + 1
    while taken.contains("\(prefix)-\(number)") { number += 1 }
    return "\(prefix)-\(number)"
  }
}
