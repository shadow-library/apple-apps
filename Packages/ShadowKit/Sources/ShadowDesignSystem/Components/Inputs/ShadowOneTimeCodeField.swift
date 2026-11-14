import SwiftUI

extension EnvironmentValues {
  @Entry var shadowVerifyingLabel: Text?
}

extension View {
  public func shadowVerifying(_ label: Text?) -> some View {
    environment(\.shadowVerifyingLabel, label)
  }
}

public struct ShadowOneTimeCodeField: View {
  private let label: LocalizedStringKey
  private let hint: LocalizedStringKey?
  private let format: ShadowOneTimeCode
  private let separator: ShadowOneTimeCodeSeparator
  private let value: (ShadowOneTimeCodeProgress) -> Text
  private let onComplete: (String) -> Void
  @Binding private var code: String

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.shadowValidationMessage) private var message
  @Environment(\.shadowVerifyingLabel) private var verifyingLabel
  @Environment(\.shadowPreviewFieldFocus) private var previewFocus
  @FocusState private var isFocused: Bool
  @State private var entry: String
  @State private var completion: ShadowOneTimeCodeCompletion
  @State private var replacesCode = false
  @State private var attempts = 0
  @ScaledMetric(relativeTo: .title2) private var boxWidth = Self.boxSize.width
  @ScaledMetric(relativeTo: .title2) private var boxHeight = Self.boxSize.height

  public init(
    _ label: LocalizedStringKey,
    code: Binding<String>,
    format: ShadowOneTimeCode = ShadowOneTimeCode(),
    separator: ShadowOneTimeCodeSeparator = .space,
    hint: LocalizedStringKey? = nil,
    value: @escaping (ShadowOneTimeCodeProgress) -> Text,
    onComplete: @escaping (String) -> Void
  ) {
    self.label = label
    self.hint = hint
    self.format = format
    self.separator = separator
    self.value = value
    self.onComplete = onComplete
    _code = code
    _entry = State(initialValue: code.wrappedValue)
    _completion = State(initialValue: ShadowOneTimeCodeCompletion(format: format, code: code.wrappedValue))
  }

  private static var boxSize: CGSize {
    ShadowDensity.current == .touch ? CGSize(width: 44, height: 52) : CGSize(width: 34, height: 38)
  }

  private var metrics: ShadowFieldMetrics { ShadowFieldMetrics(kind: .text) }
  private var isVerifying: Bool { verifyingLabel != nil }
  private var showsFocus: Bool { isEnabled && !isVerifying && (previewFocus ?? isFocused) }
  private var showsSelection: Bool { showsFocus && replacesCode && !code.isEmpty }
  private var characters: [Character] { Array(code) }

  public var body: some View {
    let shakes = !reduceMotion
    return VStack(alignment: .leading, spacing: Spacing.space2) {
      ViewThatFits(in: .horizontal) {
        boxes(.row)
        boxes(.compressedRow)
        boxes(.stacked)
      }
      .accessibilityHidden(true)
      .overlay { input }
      .contentShape(.rect)
      .onTapGesture { if isEnabled { isFocused = true } }
      .keyframeAnimator(initialValue: CGFloat.zero, trigger: attempts) { content, offset in
        content.offset(x: shakes ? offset : 0)
      } keyframes: { _ in
        KeyframeTrack {
          LinearKeyframe(-8, duration: 0.06)
          LinearKeyframe(8, duration: 0.08)
          LinearKeyframe(-6, duration: 0.08)
          LinearKeyframe(4, duration: 0.08)
          LinearKeyframe(0, duration: 0.06)
        }
      }
      footer
    }
    .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
    .sensoryFeedback(.error, trigger: attempts)
    .onChange(of: entry) { _, newValue in apply(newValue) }
    .onChange(of: code) { _, newValue in codeChanged(newValue) }
    .onChange(of: message != nil, initial: true) { wasInvalid, isInvalid in
      replacesCode = isInvalid
      if isInvalid && !wasInvalid { attempts += 1 }
    }
  }

  private var input: some View {
    TextField(label, text: $entry, prompt: Text(verbatim: ""))
      .labelsHidden()
      .textFieldStyle(.plain)
      .font(.system(size: 1))
      .foregroundStyle(.clear)
      .tint(.clear)
      .focusEffectDisabled()
      .focused($isFocused)
      .textContentType(.oneTimeCode)
      .autocorrectionDisabled()
      #if os(iOS) || os(visionOS)
        .keyboardType(format.characters == .digits ? .numberPad : .asciiCapable)
        .textInputAutocapitalization(.characters)
      #endif
      .accessibilityLabel(Text(label))
      .accessibilityValue(value(format.progress(of: code)))
      .accessibilityHint(hint.map { Text($0) } ?? Text(verbatim: ""))
  }

  private enum Arrangement {
    case row
    case compressedRow
    case stacked

    var minimumScale: CGFloat {
      switch self {
      case .row: 1
      case .compressedRow: 0.7
      case .stacked: 0
      }
    }
  }

  @ViewBuilder
  private func boxes(_ arrangement: Arrangement) -> some View {
    let groups = format.groupRanges
    let isStacked = arrangement == .stacked
    let layout = isStacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.space2)) : AnyLayout(HStackLayout(spacing: groupSpacing))
    layout {
      ForEach(groups.indices, id: \.self) { groupIndex in
        if !isStacked, groupIndex > 0, separator == .dash { dash }
        HStack(spacing: Spacing.space2) {
          ForEach(groups[groupIndex], id: \.self) { index in
            box(at: index, minimumWidth: boxWidth * arrangement.minimumScale)
          }
        }
      }
    }
  }

  private var groupSpacing: CGFloat {
    separator == .dash ? Spacing.space2 : Spacing.space5
  }

  private var dash: some View {
    Capsule()
      .fill(ShadowColor.textTertiary)
      .frame(width: Spacing.space2, height: 2)
  }

  private func box(at index: Int, minimumWidth: CGFloat) -> some View {
    let isActive = showsFocus && !showsSelection && index == format.activeIndex(in: code)
    let character = index < characters.count ? characters[index] : nil
    return ZStack {
      ShadowFieldSurface(phase: ShadowFieldPhase(isFocused: isActive, isInvalid: message != nil), metrics: metrics)
      if showsSelection, character != nil {
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(ShadowColor.accentSoft)
          .padding(Spacing.space1)
      }
      if let character {
        Text(verbatim: String(character))
          .font(.system(.title2, design: .monospaced, weight: .semibold))
          .foregroundStyle(ShadowColor.textPrimary)
          .minimumScaleFactor(0.5)
          .lineLimit(1)
      } else if isActive {
        ShadowCaret(isBlinking: previewFocus == nil, height: boxHeight * 0.5)
      }
    }
    .frame(minWidth: minimumWidth, maxWidth: boxWidth)
    .frame(height: boxHeight)
  }

  @ViewBuilder
  private var footer: some View {
    if let verifyingLabel {
      HStack(spacing: Spacing.space2) {
        ProgressView()
          .controlSize(.small)
        verifyingLabel
      }
      .shadowFont(.footnote)
      .foregroundStyle(ShadowColor.textSecondary)
      .accessibilityElement(children: .combine)
    } else if let message {
      ShadowValidationMessage(message)
    }
  }

  private func apply(_ newValue: String) {
    guard newValue != code else { return }
    guard !isVerifying else {
      entry = code
      return
    }
    let next = format.edit(from: code, to: newValue, replacingCurrent: replacesCode && !code.isEmpty)
    replacesCode = false
    code = next
    if entry != next { entry = next }
  }

  private func codeChanged(_ newValue: String) {
    if entry != newValue { entry = newValue }
    if newValue.isEmpty { replacesCode = false }
    if completion.update(newValue) { onComplete(newValue) }
  }
}

private struct ShadowCaret: View {
  let isBlinking: Bool
  let height: CGFloat

  var body: some View {
    let caret = Capsule().fill(ShadowColor.accent).frame(width: 2, height: height)
    if isBlinking {
      caret.phaseAnimator([1.0, 0.0]) { content, opacity in
        content.opacity(opacity)
      } animation: { _ in
        .easeInOut(duration: 0.5).delay(0.2)
      }
    } else {
      caret
    }
  }
}
