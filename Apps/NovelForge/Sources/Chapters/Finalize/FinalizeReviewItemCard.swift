import NovelForgeCore
import ShadowCore
import ShadowDesignSystem
import ShadowText
import SwiftUI

/// apps/novel-forge-web/src/features/chapter-workspace/FinalizeReviewItemCard.tsx:42-100: one update that needs the author's call, with its proposal, the line
/// it was read from, what a flag puts at stake, and Keep, Edit or Skip.
struct FinalizeReviewItemCard: View {
  let item: FinalizeReviewScreen.Item
  let model: FinalizeModel
  let readOnly: Bool

  var body: some View {
    let mode = model.modes[item.key]
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        Text(verbatim: item.claim).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        Spacer(minLength: Spacing.space2)
        let tag = FinalizeReviewDisplay.tag(item)
        ShadowBadge(Text(verbatim: tag.label), intent: tag.intent)
        if readOnly || item.decision != nil { ShadowBadge(Text(verbatim: FinalizeReviewDisplay.decision(item)), intent: .neutral) }
      }
      FinalizeItemProvenance(item: item)
      FinalizeItemEvidence(evidence: item.evidence)
      FinalizeItemDetails(change: item.decision == .edited ? item.edited ?? item.proposed : item.proposed)
      if let stakes = FinalizeReviewDisplay.stakes(item) { note(Text(verbatim: stakes)) }
      if item.decision == .skipped, let reason = item.reason, mode != .skip { note(Text("Skipped because: \(reason)", tableName: "Finalize")) }
      if mode == .edit { FinalizeEditForm(item: item, model: model) }
      if mode == .skip { FinalizeSkipForm(item: item, model: model) }
      if let problem = model.problem(for: item.key) { problem.text.shadowFont(.footnote).foregroundStyle(ShadowColor.dangerText) }
      if !readOnly { actions(mode) }
    }
    .padding(Spacing.space4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .shadowCard()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: item.claim))
  }

  private func actions(_ mode: FinalizeModel.Mode?) -> some View {
    HStack(spacing: Spacing.space2) {
      FinalizeChoiceButton(isSelected: mode == nil && item.decision == .kept, title: Text("Keep", tableName: "Finalize")) {
        model.setMode(nil, for: item.key)
        guard item.decision != .kept else { return }
        Task { await model.answer(item, .keep) }
      }
      FinalizeChoiceButton(isSelected: mode == .edit || (mode == nil && item.decision == .edited), title: Text("Edit", tableName: "Finalize")) {
        model.setMode(.edit, for: item.key)
      }
      .disabled(!FinalizeEditFields.isEditable(item))
      FinalizeChoiceButton(isSelected: mode == .skip || (mode == nil && item.decision == .skipped), title: Text("Skip", tableName: "Finalize")) {
        model.setMode(.skip, for: item.key)
      }
    }
    .disabled(model.deciding)
    .accessibilityLabel(Text("Decision for \(item.claim)", tableName: "Finalize"))
  }

  private func note(_ text: Text) -> some View {
    text.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
  }
}

/// apps/novel-forge-web/src/features/chapter-workspace/FinalizeReviewDialog.tsx:364-407: a routine update as one row, kept or skipped without opening a card.
struct FinalizeRoutineRow: View {
  let item: FinalizeReviewScreen.Item
  let model: FinalizeModel
  let readOnly: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        Text(verbatim: FinalizeReviewDisplay.category(item.category)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
        Text(verbatim: item.claim).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
        Spacer(minLength: Spacing.space2)
        if readOnly || item.decision != nil {
          Text(verbatim: FinalizeReviewDisplay.decision(item)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
        }
        if !readOnly { actions }
      }
      FinalizeItemProvenance(item: item)
      if model.modes[item.key] == .skip { FinalizeSkipForm(item: item, model: model) }
      if let problem = model.problem(for: item.key) { problem.text.shadowFont(.footnote).foregroundStyle(ShadowColor.dangerText) }
    }
  }

  private var actions: some View {
    HStack(spacing: Spacing.space2) {
      if item.decision != .kept {
        Button {
          Task { await model.answer(item, .keep) }
        } label: {
          Text("Keep", tableName: "Finalize")
        }
        .accessibilityLabel(Text("Keep: \(item.claim)", tableName: "Finalize"))
      }
      if item.decision != .skipped {
        Button {
          model.setMode(.skip, for: item.key)
        } label: {
          Text("Skip", tableName: "Finalize")
        }
        .accessibilityLabel(Text("Skip: \(item.claim)", tableName: "Finalize"))
      }
    }
    .buttonStyle(.borderless)
    .disabled(model.deciding)
  }
}

/// Which read an answer came from: carried from an earlier revision's, or open again because this read changed what the author had answered.
struct FinalizeItemProvenance: View {
  enum Mark: Equatable {
    case carriedOver
    case reopened
  }

  let item: FinalizeReviewScreen.Item

  static func marks(_ item: FinalizeReviewScreen.Item) -> [Mark] {
    (item.carriedOver ? [.carriedOver] : []) + (item.reopened ? [.reopened] : [])
  }

  var body: some View {
    ForEach(Self.marks(item), id: \.self) { mark in
      switch mark {
      case .carriedOver:
        Label(title: { Text("Answered on an earlier read", tableName: "Finalize") }, icon: { Image(systemName: "arrow.uturn.forward") })
          .shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      case .reopened:
        Label(title: { Text("Changed since you answered it", tableName: "Finalize") }, icon: { Image(systemName: "arrow.triangle.2.circlepath") })
          .shadowFont(.caption).foregroundStyle(ShadowColor.warningText)
      }
    }
  }
}

struct FinalizeItemEvidence: View {
  let evidence: String?

  var body: some View {
    if let line = FinalizeReviewDisplay.evidence(evidence) {
      Group {
        if let label = line.label { Text(verbatim: "\(label) \(line.text)") } else { Text(verbatim: line.text) }
      }
      .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    }
  }
}

struct FinalizeItemDetails: View {
  let change: [String: JSONValue]

  var body: some View {
    let details = FinalizeReviewDisplay.details(of: change)
    if !details.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        ForEach(details.indices, id: \.self) { index in
          FinalizeDetailLine(detail: FinalizePresentation.Detail(label: details[index].label, value: details[index].value))
        }
      }
    }
  }
}

struct FinalizeDetailLine: View {
  let detail: FinalizePresentation.Detail

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.space1) {
      Text(verbatim: "\(detail.label):").foregroundStyle(ShadowColor.textSecondary)
      Text(verbatim: detail.value).foregroundStyle(ShadowColor.textPrimary)
    }
    .shadowFont(.footnote)
  }
}

struct FinalizeChoiceButton: View {
  let isSelected: Bool
  let title: Text
  let action: () -> Void

  var body: some View {
    if isSelected {
      Button(action: action) { title }.buttonStyle(.borderedProminent).accessibilityAddTraits(.isSelected)
    } else {
      Button(action: action) { title }.buttonStyle(.bordered)
    }
  }
}

/// FinalizeReviewItemCard.tsx:183-220: the core refuses a skip without a reason, so the reason is asked before the skip is sent.
struct FinalizeSkipForm: View {
  let item: FinalizeReviewScreen.Item
  let model: FinalizeModel
  @State private var reason: String

  init(item: FinalizeReviewScreen.Item, model: FinalizeModel) {
    self.item = item
    self.model = model
    _reason = State(initialValue: item.reason ?? "")
  }

  /// FinalizeReviewItemCard.tsx:186-189 with the core's own trim: nil while there is nothing to send.
  static func reason(_ text: String) -> String? {
    let trimmed = text.jsTrim()
    return trimmed.isEmpty ? nil : trimmed
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      TextField(text: $reason, prompt: Text("Why skip it?", tableName: "Finalize")) {
        Text("Reason for skipping \(item.claim)", tableName: "Finalize")
      }
      .textFieldStyle(.roundedBorder)
      .onSubmit(submit)
      Text("A skipped update is never asked again for this chapter.", tableName: "Finalize").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      HStack(spacing: Spacing.space2) {
        Button(action: submit) {
          Text("Skip", tableName: "Finalize")
        }
        .buttonStyle(.bordered)
        .disabled(Self.reason(reason) == nil)
        Button {
          model.setMode(nil, for: item.key)
        } label: {
          Text("Cancel", tableName: "Finalize")
        }
        .buttonStyle(.borderless)
      }
      .disabled(model.deciding)
    }
  }

  private func submit() {
    guard let reason = Self.reason(reason) else { return }
    Task { await model.answer(item, .skip(reason: reason)) }
  }
}

/// FinalizeReviewItemCard.tsx:109-172: the fields an edit may change, starting from what finalize would apply.
struct FinalizeEditForm: View {
  let item: FinalizeReviewScreen.Item
  let model: FinalizeModel
  @State private var values: [String: FinalizeEditFields.Value]
  @State private var problem: String?

  init(item: FinalizeReviewScreen.Item, model: FinalizeModel) {
    self.item = item
    self.model = model
    _values = State(initialValue: FinalizeEditFields.values(item))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("About \(item.subject). The record it names stays as it is.", tableName: "Finalize").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      ForEach(FinalizeEditFields.fields(of: item.proposed), id: \.key) { field in
        input(field)
      }
      if let problem { Text(verbatim: problem).shadowFont(.footnote).foregroundStyle(ShadowColor.dangerText) }
      HStack(spacing: Spacing.space2) {
        Button(action: save) {
          Text("Save Edit", tableName: "Finalize")
        }
        .buttonStyle(.borderedProminent)
        Button {
          model.setMode(nil, for: item.key)
        } label: {
          Text("Cancel", tableName: "Finalize")
        }
        .buttonStyle(.borderless)
      }
      .disabled(model.deciding)
    }
  }

  @ViewBuilder
  private func input(_ field: FinalizeEditFields.Field) -> some View {
    switch field.kind {
    case .flag:
      Toggle(isOn: flag(field.key)) { Text(verbatim: field.label) }
    case .choice(let options):
      Picker(selection: text(field.key)) {
        ForEach(options, id: \.self) { option in Text(verbatim: option).tag(option) }
      } label: {
        Text(verbatim: field.label)
      }
      .pickerStyle(.segmented)
    case .longText:
      VStack(alignment: .leading, spacing: Spacing.space1) {
        Text(verbatim: field.label).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
        TextEditor(text: text(field.key)).frame(minHeight: 60).accessibilityLabel(Text(verbatim: field.label))
      }
    case .text, .list:
      TextField(text: text(field.key), prompt: Text(verbatim: field.label)) { Text(verbatim: field.label) }.textFieldStyle(.roundedBorder)
    }
  }

  private func text(_ key: String) -> Binding<String> {
    Binding(
      get: { if case .text(let value)? = values[key] { value } else { "" } },
      set: {
        values[key] = .text($0)
        problem = nil
      })
  }

  private func flag(_ key: String) -> Binding<Bool> {
    Binding(
      get: { values[key] == .flag(true) },
      set: {
        values[key] = .flag($0)
        problem = nil
      })
  }

  private func save() {
    switch FinalizeEditFields.patch(item, values: values) {
    case .problem(let reason): problem = reason
    case .patch(let patch): Task { await model.answer(item, .edit(patch)) }
    }
  }
}
