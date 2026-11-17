import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

extension ProgressItemKey {
  var title: LocalizedStringResource {
    switch self {
    case .premise: LocalizedStringResource("Premise", table: "Library")
    case .protagonist: LocalizedStringResource("Protagonist", table: "Library")
    case .opposition: LocalizedStringResource("Opposition", table: "Library")
    case .theme: LocalizedStringResource("Theme", table: "Library")
    case .readerPromise: LocalizedStringResource("Reader promise", table: "Library")
    case .ending: LocalizedStringResource("Ending", table: "Library")
    case .firstVolumeGoal: LocalizedStringResource("First volume goal", table: "Library")
    case .nextChapterPlanned: LocalizedStringResource("Next chapter planned", table: "Library")
    }
  }

  var reason: LocalizedStringResource {
    switch self {
    case .premise: LocalizedStringResource("The one- or two-line idea the chat and every later decision build on.", table: "Library")
    case .protagonist: LocalizedStringResource("Who the reader follows; scenes and knowledge are written from their point of view.", table: "Library")
    case .opposition: LocalizedStringResource("What or who pushes back, so chapters have something to write against.", table: "Library")
    case .theme: LocalizedStringResource("What the book is about underneath the plot.", table: "Library")
    case .readerPromise: LocalizedStringResource("What the reader is waiting for and expects to be paid off.", table: "Library")
    case .ending: LocalizedStringResource("How the book ends. Planner-only, never shown to the reader early, and fine to leave undecided for now.", table: "Library")
    case .firstVolumeGoal: LocalizedStringResource("What changes by the end of volume one.", table: "Library")
    case .nextChapterPlanned: LocalizedStringResource("A short plan for the next chapter, agreed with the chat before it is written.", table: "Library")
    }
  }
}

extension ProgressStatus {
  var title: LocalizedStringResource {
    switch self {
    case .open: LocalizedStringResource("Open", table: "Library")
    case .answered: LocalizedStringResource("Settled", table: "Library")
    case .undecided: LocalizedStringResource("Undecided for now", table: "Library")
    case .dismissed: LocalizedStringResource("Dismissed", table: "Library")
    }
  }

  var intent: ShadowBadgeIntent {
    switch self {
    case .open: .neutral
    case .answered: .success
    case .undecided: .info
    case .dismissed: .neutral
    }
  }
}

struct ChecklistCardView: View {
  let model: ChecklistModel

  var body: some View {
    switch model.card {
    case .loading, .hidden: EmptyView()
    case .failed(let error): failed(error)
    case .unavailable: unavailable
    case .shown(let checklist): card(checklist)
    case .dismissedOnly(let checklist): dismissedRow(checklist)
    }
  }

  private func failed(_ error: PresentedError) -> some View {
    ShadowCallout(Text("Getting started could not be read", tableName: "Library"), message: error.text, intent: .danger) {
      Button {
        model.retry()
      } label: {
        Text("Try Again", tableName: "Library")
      }
    }
  }

  private func dismissedRow(_ checklist: Checklist) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      if let failure = model.failure { ShadowValidationMessage(failure.text) }
      dismissed(checklist)
    }
  }

  private var unavailable: some View {
    ShadowCallout(
      Text("Getting started is unavailable", tableName: "Library"), message: Text("It is not up to date on this device yet. Try again after syncing.", tableName: "Library"),
      intent: .warning)
  }

  private func card(_ checklist: Checklist) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        ProgressView(value: Double(checklist.percent), total: 100) {
          Text("Getting started", tableName: "Library").shadowFont(.headline).accessibilityAddTraits(.isHeader)
        } currentValueLabel: {
          Text("\(checklist.percent)% settled", tableName: "Library")
        }
        .progressViewStyle(.shadowLinear)
        if let failure = model.failure { ShadowValidationMessage(failure.text) }
        ForEach(checklist.visible, id: \.key) { item in row(item) }
        dismissed(checklist)
      }
    }
  }

  private func row(_ item: ChecklistItem) -> some View {
    HStack(alignment: .top, spacing: Spacing.space3) {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        HStack(spacing: Spacing.space2) {
          Text(item.key.title).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
          ShadowBadge(Text(item.status.title), intent: item.status.intent)
        }
        Text(item.key.reason).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      Spacer(minLength: 0)
      actions(item)
    }
  }

  @ViewBuilder
  private func actions(_ item: ChecklistItem) -> some View {
    switch item.status {
    case .open:
      menu(item) {
        Button {
          Task { await model.markUndecided(item.key) }
        } label: {
          Text("Undecided for now", tableName: "Library")
        }
        Button {
          Task { await model.dismiss(item.key) }
        } label: {
          Text("Dismiss", tableName: "Library")
        }
      }
    case .undecided:
      menu(item) {
        Button {
          Task { await model.clear(item.key) }
        } label: {
          Text("Clear", tableName: "Library")
        }
      }
    case .answered, .dismissed: EmptyView()
    }
  }

  private func menu(_ item: ChecklistItem, @ViewBuilder content: () -> some View) -> some View {
    Menu {
      content()
    } label: {
      Label(title: { Text("Actions for \(String(localized: item.key.title))", tableName: "Library") }, icon: { Image(systemName: "ellipsis.circle") })
        .labelStyle(.iconOnly)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(model.busy.contains(item.key))
  }

  @ViewBuilder
  private func dismissed(_ checklist: Checklist) -> some View {
    let hidden = checklist.items.filter { $0.status == .dismissed }
    if !hidden.isEmpty {
      Menu {
        ForEach(hidden, id: \.key) { item in
          Button {
            Task { await model.clear(item.key) }
          } label: {
            Text("Bring back \(String(localized: item.key.title))", tableName: "Library")
          }
        }
      } label: {
        Text("\(hidden.count) dismissed · Bring back", tableName: "Library")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
  }
}
