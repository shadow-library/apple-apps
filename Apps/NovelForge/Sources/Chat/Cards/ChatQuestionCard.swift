import Foundation
import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

extension ChatQuestion {
  /// chat-view.ts:426-452: a progress key the checklist does not know is dropped.
  var progressItem: ProgressItemKey? { progressKey.flatMap(ProgressItemKey.init(rawValue:)) }
}

/// QuestionCard.tsx: an option's title is sent as the author's next message, and a later message settles the question.
struct ChatQuestionCard: View {
  let question: ChatQuestion
  let isSettled: Bool
  let isDisabled: Bool
  let answer: (String) async -> Void
  let leaveUndecided: (ProgressItemKey?) async -> Void
  @State private var selected: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      eyebrow.shadowFont(.caption).foregroundStyle(ShadowColor.accentText).textCase(.uppercase)
      Text(verbatim: question.question).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
      if let why = question.why { Text(verbatim: why).shadowFont(.callout).foregroundStyle(ShadowColor.textSecondary) }
      VStack(alignment: .leading, spacing: Spacing.space2) {
        ForEach(Array(question.answers.enumerated()), id: \.offset) { index, option in optionButton(option, at: index) }
      }
      if !isSettled { footer }
    }
    .padding(Spacing.space4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ShadowColor.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .opacity(isSettled ? 0.7 : 1)
  }

  private var eyebrow: Text {
    guard let key = question.progressItem else { return Text("Question", tableName: "ChatCards") }
    return Text(key.title)
  }

  private var isLocked: Bool { isSettled || isDisabled }

  private var chosen: ChatQuestionAnswer? {
    guard let selected, !isSettled, question.answers.indices.contains(selected) else { return nil }
    return question.answers[selected]
  }

  private func optionButton(_ option: ChatQuestionAnswer, at index: Int) -> some View {
    let isChosen = !isSettled && selected == index
    return Button {
      selected = selected == index ? nil : index
    } label: {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        HStack(spacing: Spacing.space2) {
          Text(verbatim: option.title).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
          if option.recommended { ShadowBadge(Text("Forge's pick", tableName: "ChatCards"), intent: .accent) }
        }
        if let why = option.why { Text(verbatim: why).shadowFont(.callout).foregroundStyle(ShadowColor.textSecondary) }
        if let tradeOff = option.tradeOff {
          Text("Trade-off: \(tradeOff)", tableName: "ChatCards").shadowFont(.caption).foregroundStyle(ShadowColor.textTertiary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.space3)
      .background(isChosen ? ShadowColor.accentSoft : ShadowColor.surfaceApp, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(isChosen ? ShadowColor.accent : ShadowColor.borderSubtle)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isLocked)
    .accessibilityAddTraits(isChosen ? .isSelected : [])
  }

  private var footer: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Spacing.space2) {
        undecided
        Spacer(minLength: Spacing.space2)
        confirm
      }
      VStack(alignment: .leading, spacing: Spacing.space2) {
        confirm
        undecided
      }
    }
  }

  private var undecided: some View {
    Button {
      Task { await leaveUndecided(question.progressItem) }
    } label: {
      Text("Undecided for Now", tableName: "ChatCards")
    }
    .buttonStyle(.borderless)
    .disabled(isDisabled)
  }

  private var confirm: some View {
    Button {
      guard let chosen else { return }
      Task { await answer(chosen.title) }
    } label: {
      if let chosen {
        Text("Answer: \(chosen.title)", tableName: "ChatCards").lineLimit(1)
      } else {
        Text("Choose an Option", tableName: "ChatCards")
      }
    }
    .buttonStyle(.borderedProminent)
    .disabled(isDisabled || chosen == nil)
  }
}
