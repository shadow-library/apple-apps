import SwiftUI

extension EnvironmentValues {
  @Entry var shadowPreviewTokenSelection: Int?
}

extension View {
  @_spi(Preview) public func shadowPreviewTokenSelection(_ index: Int?) -> some View {
    environment(\.shadowPreviewTokenSelection, index)
  }
}

public struct ShadowTokenField<Value: Hashable & Sendable>: View {
  private let title: LocalizedStringKey
  private let prompt: Text?
  private let suggestions: [Value]
  private let rules: ShadowTokenRules<Value>
  private let removeLabel: (Value) -> Text
  private let externalText: Binding<String>?
  @Binding private var tokens: [Value]

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.shadowValidationMessage) private var message
  @Environment(\.shadowPreviewFieldFocus) private var previewFocus
  @Environment(\.shadowPreviewTokenSelection) private var previewSelection
  @FocusState private var isFocused: Bool
  @State private var ownText: String
  @State private var raw: String
  @State private var selection: Int?
  @State private var highlighted: Int?
  @State private var rejections = 0

  public init(
    _ title: LocalizedStringKey,
    tokens: Binding<[Value]>,
    text: Binding<String>? = nil,
    prompt: Text? = nil,
    suggestions: [Value] = [],
    rules: ShadowTokenRules<Value>,
    removeLabel: @escaping (Value) -> Text
  ) {
    self.title = title
    self.prompt = prompt
    self.suggestions = suggestions
    self.rules = rules
    self.removeLabel = removeLabel
    externalText = text
    _tokens = tokens
    _ownText = State(initialValue: text?.wrappedValue ?? "")
    _raw = State(initialValue: ShadowTokenTextInput.raw(for: text?.wrappedValue ?? ""))
  }

  private var text: String { externalText?.wrappedValue ?? ownText }
  private var metrics: ShadowFieldMetrics { ShadowFieldMetrics(kind: .text) }
  private var showsFocus: Bool { isEnabled && (previewFocus ?? isFocused) }
  private var visibleSelection: Int? { (previewSelection ?? selection).flatMap { tokens.indices.contains($0) ? $0 : nil } }
  private var matches: [Value] { showsFocus ? rules.suggestions(from: suggestions, matching: text, excluding: tokens) : [] }

  public var body: some View {
    let matches = matches
    VStack(alignment: .leading, spacing: Spacing.space1) {
      field
      if !matches.isEmpty {
        ShadowTokenSuggestions(values: matches, label: rules.label, highlighted: highlighted, choose: choose)
          .padding(.top, Spacing.space1)
      }
      if let message { ShadowValidationMessage(message) }
    }
    .sensoryFeedback(.warning, trigger: rejections)
    .onChange(of: raw) { _, newValue in rawChanged(newValue) }
    .onChange(of: externalText?.wrappedValue) { _, newValue in
      guard let newValue, newValue != ownText else { return }
      ownText = newValue
      raw = ShadowTokenTextInput.raw(for: newValue)
    }
    .onChange(of: isFocused) { _, focused in
      guard !focused else { return }
      update { [$0.commit(rules: rules)] }
      selection = nil
      highlighted = nil
    }
    .onChange(of: text) { highlighted = nil }
  }

  private var field: some View {
    ShadowFlowLayout(spacing: Spacing.space1 + Spacing.space05) {
      ForEach(tokens, id: \.self) { value in
        let index = tokens.firstIndex(of: value) ?? 0
        ShadowTag(
          verbatim: rules.label(value),
          isSelected: index == visibleSelection,
          removeLabel: removeLabel(value),
          select: { select(index) },
          remove: { remove(at: index) }
        )
      }
      input.shadowFlowFill()
    }
    .padding(.horizontal, metrics.density == .touch ? Spacing.space3 : Spacing.space1 + Spacing.space05)
    .padding(.vertical, Spacing.space1 + Spacing.space05)
    .frame(minHeight: metrics.minHeight)
    .background { ShadowFieldSurface(phase: ShadowFieldPhase(isFocused: showsFocus, isInvalid: message != nil), metrics: metrics) }
    .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
    .contentShape(.rect)
    .onTapGesture { if isEnabled { isFocused = true } }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(title))
  }

  private var input: some View {
    sizingText
      .shadowFont(.body)
      .lineLimit(1)
      .hidden()
      .frame(minWidth: Spacing.space10 + Spacing.space6, maxWidth: .infinity, alignment: .leading)
      .overlay {
        TextField(title, text: $raw, prompt: Text(verbatim: ""))
          .labelsHidden()
          .textFieldStyle(.plain)
          .shadowFont(.body)
          .foregroundStyle(ShadowColor.textPrimary)
          .focusEffectDisabled()
          .focused($isFocused)
          .accessibilityValue(Text(verbatim: text))
          .autocorrectionDisabled()
          #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.never)
          #endif
          .submitLabel(.done)
          .onSubmit(submit)
          .onKeyPress(.downArrow) { moveHighlight(by: 1) }
          .onKeyPress(.upArrow) { moveHighlight(by: -1) }
          .onKeyPress(.escape) {
            guard highlighted != nil || selection != nil else { return .ignored }
            highlighted = nil
            selection = nil
            return .handled
          }
      }
      .overlay(alignment: .leading) {
        if let placeholder {
          placeholder
            .shadowFont(.body)
            .foregroundStyle(ShadowColor.textPlaceholder)
            .lineLimit(1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
  }

  private var placeholder: Text? {
    text.isEmpty && tokens.isEmpty ? prompt : nil
  }

  private var sizingText: Text {
    placeholder ?? Text(verbatim: text.isEmpty ? " " : text)
  }

  private func rawChanged(_ newValue: String) {
    let interpretation = ShadowTokenTextInput.interpret(newValue, currentText: text)
    if let normalized = interpretation.raw { raw = normalized }
    switch interpretation.change {
    case .none: break
    case .backspaceOnEmpty: deleteBackward()
    case .text(let clean): update { $0.type(clean, rules: rules) }
    }
  }

  private func submit() {
    if let highlighted, let value = matches[safe: highlighted] {
      choose(value)
    } else {
      update { [$0.commit(rules: rules)] }
    }
    isFocused = true
  }

  private func choose(_ value: Value) {
    update { entry in
      let outcome = entry.add(value, rules: rules)
      if outcome != .limitReached { entry.text = "" }
      return [outcome]
    }
    highlighted = nil
    isFocused = true
  }

  private func select(_ index: Int) {
    guard isEnabled else { return }
    selection = selection == index ? nil : index
    isFocused = true
  }

  private func remove(at index: Int) {
    update { entry in
      entry.remove(at: index)
      return []
    }
  }

  private func deleteBackward() {
    update { entry in
      entry.deleteBackward()
      return []
    }
  }

  private func moveHighlight(by delta: Int) -> KeyPress.Result {
    let count = matches.count
    guard count > 0 else { return .ignored }
    highlighted = ((highlighted ?? (delta > 0 ? -1 : count)) + delta + count) % count
    return .handled
  }

  private func update(_ change: (inout ShadowTokenEntry<Value>) -> [ShadowTokenOutcome]) {
    var entry = ShadowTokenEntry(tokens: tokens, text: text, selection: selection)
    let outcomes = change(&entry)
    if outcomes.contains(where: \.isRejection) { rejections += 1 }
    applyEntry(entry)
  }

  private func applyEntry(_ entry: ShadowTokenEntry<Value>) {
    if entry.tokens != tokens { tokens = entry.tokens }
    selection = entry.selection
    if entry.text != text {
      ownText = entry.text
      externalText?.wrappedValue = entry.text
    }
    if let normalized = ShadowTokenTextInput.normalized(raw, for: entry.text) { raw = normalized }
  }
}

extension ShadowTokenField where Value == String {
  public init(
    _ title: LocalizedStringKey,
    tokens: Binding<[String]>,
    text: Binding<String>? = nil,
    prompt: Text? = nil,
    suggestions: [String] = [],
    maximumCount: Int? = nil,
    comparison: ShadowTokenComparison = .caseInsensitive,
    removeLabel: @escaping (String) -> Text
  ) {
    self.init(
      title, tokens: tokens, text: text, prompt: prompt, suggestions: suggestions,
      rules: ShadowTokenRules(maximumCount: maximumCount, comparison: comparison), removeLabel: removeLabel)
  }
}

struct ShadowTokenSuggestions<Value: Hashable & Sendable>: View {
  let values: [Value]
  let label: (Value) -> String
  let highlighted: Int?
  let choose: (Value) -> Void

  private var density: ShadowDensity { ShadowDensity.current }
  private var radius: CGFloat { density == .touch ? Radius.xl : Radius.lg }

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(values.enumerated()), id: \.element) { index, value in
        if index > 0, density == .touch {
          Divider().padding(.leading, Spacing.space4)
        }
        row(value, isHighlighted: index == highlighted)
      }
    }
    .padding(density == .touch ? 0 : Spacing.space1)
    .background(ShadowColor.surfaceRaised, in: .rect(cornerRadius: radius, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(ShadowColor.borderDefault, lineWidth: 1) }
    .shadowElevation(.e2)
  }

  private func row(_ value: Value, isHighlighted: Bool) -> some View {
    Button {
      choose(value)
    } label: {
      Text(verbatim: label(value))
        .shadowFont(.body)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(isHighlighted && density == .compact ? ShadowColor.onAccent : ShadowColor.textPrimary)
        .frame(maxWidth: .infinity, minHeight: density == .touch ? ShadowMetrics.rowTouch : ShadowMetrics.controlMacMd - 4, alignment: .leading)
        .padding(.horizontal, density == .touch ? Spacing.space4 : Spacing.space2)
        .background {
          if isHighlighted {
            RoundedRectangle(cornerRadius: density == .touch ? 0 : Radius.sm, style: .continuous)
              .fill(density == .touch ? ShadowColor.accentSoft : ShadowColor.selectionRow)
          }
        }
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isHighlighted ? .isSelected : [])
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
