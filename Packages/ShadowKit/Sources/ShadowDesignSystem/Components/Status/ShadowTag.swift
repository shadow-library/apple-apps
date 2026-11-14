import SwiftUI

public struct ShadowTag: View {
  private enum Mode {
    case plain
    case filter(Binding<Bool>)
    case action(() -> Void)
    case removable(isSelected: Bool, select: (() -> Void)?, remove: () -> Void, removeLabel: Text)
  }

  private let title: Text
  private let systemImage: String?
  private let mode: Mode

  public init(_ titleKey: LocalizedStringKey, systemImage: String? = nil) {
    self.init(title: Text(titleKey), systemImage: systemImage, mode: .plain)
  }

  public init(_ titleKey: LocalizedStringKey, systemImage: String? = nil, isSelected: Binding<Bool>) {
    self.init(title: Text(titleKey), systemImage: systemImage, mode: .filter(isSelected))
  }

  public init(_ titleKey: LocalizedStringKey, systemImage: String? = nil, action: @escaping () -> Void) {
    self.init(title: Text(titleKey), systemImage: systemImage, mode: .action(action))
  }

  public init(_ titleKey: LocalizedStringKey, systemImage: String? = nil, removeLabel: LocalizedStringKey, remove: @escaping () -> Void) {
    self.init(title: Text(titleKey), systemImage: systemImage, mode: .removable(isSelected: false, select: nil, remove: remove, removeLabel: Text(removeLabel)))
  }

  init(verbatim title: String, isSelected: Bool, removeLabel: Text, select: @escaping () -> Void, remove: @escaping () -> Void) {
    self.init(
      title: Text(verbatim: title), systemImage: nil, mode: .removable(isSelected: isSelected, select: select, remove: remove, removeLabel: removeLabel))
  }

  private init(title: Text, systemImage: String?, mode: Mode) {
    self.title = title
    self.systemImage = systemImage
    self.mode = mode
  }

  public var body: some View {
    switch mode {
    case .plain:
      ShadowTagChrome(appearance: .outlined, interaction: nil) { label }
    case .filter(let isSelected):
      Toggle(isOn: isSelected) { label }
        .toggleStyle(ShadowTagToggleStyle())
    case .action(let action):
      Button(action: action) { label }
        .buttonStyle(ShadowTagButtonStyle(appearance: .outlined))
    case .removable(let isSelected, let select, let remove, let removeLabel):
      ShadowRemovableTag(label: label, isSelected: isSelected, select: select, remove: remove, removeLabel: removeLabel)
    }
  }

  private var label: some View {
    HStack(spacing: Spacing.space1 + Spacing.space05) {
      if let systemImage {
        Image(systemName: systemImage)
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      title
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

enum ShadowTagAppearance: Hashable {
  case outlined
  case selected
  case soft
}

struct ShadowTagChrome<Content: View>: View {
  let appearance: ShadowTagAppearance
  let interaction: ShadowButtonInteraction?
  var trailingInset: CGFloat?
  @ViewBuilder let content: Content

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.shadowPreviewInteraction) private var previewInteraction
  @ScaledMetric(relativeTo: .subheadline) private var scale = 1

  private var metrics: ShadowTagMetrics { ShadowTagMetrics(size: ShadowControlSize(controlSize)) }
  private var phase: ShadowButtonInteraction { previewInteraction ?? interaction ?? .idle }

  var body: some View {
    let metrics = metrics
    content
      .font(Font.shadow(metrics.style).weight(.medium))
      .foregroundStyle(foreground)
      .padding(.leading, metrics.leadingPadding)
      .padding(.trailing, trailingInset ?? metrics.trailingPadding)
      .frame(minHeight: metrics.height * scale)
      .background(fill, in: .capsule)
      .overlay { Capsule().strokeBorder(border, lineWidth: border == .clear ? 0 : 1) }
      .contentShape(Capsule().inset(by: -metrics.hitOutset))
      .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
  }

  private var foreground: Color {
    switch appearance {
    case .outlined: ShadowColor.textPrimary
    case .selected: ShadowColor.onAccent
    case .soft: ShadowColor.accentText
    }
  }

  private var fill: Color {
    switch (appearance, phase) {
    case (.outlined, .idle): ShadowColor.surfaceCard
    case (.outlined, .hovered): ShadowColor.bgHover
    case (.outlined, .pressed): ShadowColor.bgPressed
    case (.selected, .idle): ShadowColor.accent
    case (.selected, .hovered): ShadowColor.accentHover
    case (.selected, .pressed): ShadowColor.accentActive
    case (.soft, .pressed): ShadowColor.accentSoft.opacity(0.6)
    case (.soft, _): ShadowColor.accentSoft
    }
  }

  private var border: Color {
    switch appearance {
    case .outlined: contrast == .increased ? ShadowColor.borderStrong : ShadowColor.borderDefault
    case .selected: ShadowColor.accent
    case .soft: contrast == .increased ? ShadowColor.accentText : .clear
    }
  }
}

private struct ShadowTagButtonStyle: ButtonStyle {
  let appearance: ShadowTagAppearance

  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    ShadowTagChrome(appearance: appearance, interaction: configuration.isPressed ? .pressed : isHovered ? .hovered : .idle) { configuration.label }
      .onHover { isHovered = $0 }
  }
}

private struct ShadowTagToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      configuration.label
    }
    .buttonStyle(ShadowTagButtonStyle(appearance: configuration.isOn ? .selected : .outlined))
    .accessibilityAddTraits(configuration.isOn ? [.isToggle, .isSelected] : .isToggle)
  }
}

private struct ShadowRemovableTag<Label: View>: View {
  let label: Label
  let isSelected: Bool
  let select: (() -> Void)?
  let remove: () -> Void
  let removeLabel: Text

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize
  @ScaledMetric(relativeTo: .subheadline) private var scale = 1

  private var metrics: ShadowTagMetrics { ShadowTagMetrics(size: ShadowControlSize(controlSize)) }
  private var isTouch: Bool { ShadowDensity.current == .touch }

  var body: some View {
    let metrics = metrics
    ShadowTagChrome(appearance: isSelected ? .selected : .soft, interaction: nil, trailingInset: Spacing.space1) {
      HStack(spacing: isTouch ? Spacing.space1 : Spacing.space05) {
        label.accessibilityAddTraits(isSelected ? .isSelected : [])
        Button(action: remove) {
          Image(systemName: "xmark")
            .imageScale(.small)
            .fontWeight(.semibold)
            .frame(minWidth: isTouch ? Spacing.space5 : Spacing.space4, minHeight: metrics.height * scale)
            .contentShape(Rectangle().inset(by: -metrics.hitOutset))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(removeLabel)
      }
    }
    .onTapGesture { if isEnabled { select?() } }
    .accessibilityElement(children: .contain)
  }
}
