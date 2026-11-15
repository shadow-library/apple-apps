import SwiftUI

nonisolated public enum ShadowListAccessory: Hashable, Sendable {
  case none
  case chevron
}

extension EnvironmentValues {
  @Entry var shadowDrawsRowBackground = false
}

nonisolated public enum ShadowSymbolTileStyle: Hashable, Sendable, CaseIterable {
  case soft
  case filled
}

nonisolated public enum ShadowSymbolTileSize: Hashable, Sendable, CaseIterable {
  case regular
  case large
}

public struct ShadowSymbolTile: View {
  private let systemImage: String
  private let tint: ShadowAvatarTint
  private let style: ShadowSymbolTileStyle
  private let size: ShadowSymbolTileSize
  @ScaledMetric private var side: CGFloat

  public init(systemImage: String, tint: ShadowAvatarTint = .accent, style: ShadowSymbolTileStyle = .soft, size: ShadowSymbolTileSize = .regular) {
    self.systemImage = systemImage
    self.tint = tint
    self.style = style
    self.size = size
    _side = ScaledMetric(wrappedValue: size == .large ? ShadowSymbolTileMetrics.largeSide : ShadowListMetrics().tileSize, relativeTo: size == .large ? .title : .body)
  }

  public var body: some View {
    let metrics = ShadowListMetrics()
    Image(systemName: systemImage)
      .font(glyphFont)
      .foregroundStyle(style == .filled ? tint.filledForeground : tint.foreground)
      .frame(width: side, height: side)
      .background(style == .filled ? tint.filledBackground : tint.background, in: .rect(cornerRadius: size == .large ? Radius.xl : metrics.tileCornerRadius, style: .continuous))
      .accessibilityHidden(true)
  }

  private var glyphFont: Font {
    if size == .large { return .title }
    return ShadowDensity.current == .touch ? .body : .footnote
  }
}

nonisolated enum ShadowSymbolTileMetrics {
  static let largeSide: CGFloat = 52
}

public struct ShadowListRow<Leading: View, Trailing: View>: View {
  private let title: Text
  private let subtitle: Text?
  private let caption: Text?
  private let value: Text?
  private let accessory: ShadowListAccessory
  private let role: ButtonRole?
  private let isSelected: Bool
  private let isEmphasized: Bool
  private let hasLeading: Bool
  private let leading: Leading
  private let trailing: Trailing

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.shadowDrawsRowBackground) private var drawsBackground
  @Environment(\.displayScale) private var displayScale
  @Environment(\.shadowHoverEffectsEnabled) private var hoverEffectsEnabled
  @Environment(\.appearsActive) private var appearsActive
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .body) private var minimumHeight = ShadowListMetrics().minimumRowHeight
  @State private var leadingWidth = ShadowListMetrics().tileSize
  @State private var isHovered = false

  init(
    title: Text, subtitle: Text?, caption: Text?, value: Text?, accessory: ShadowListAccessory, role: ButtonRole?, isSelected: Bool, isEmphasized: Bool, hasLeading: Bool,
    leading: Leading, trailing: Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.caption = caption
    self.value = value
    self.accessory = accessory
    self.role = role
    self.isSelected = isSelected
    self.isEmphasized = isEmphasized
    self.hasLeading = hasLeading
    self.leading = leading
    self.trailing = trailing
  }

  public init(
    title: Text,
    subtitle: Text? = nil,
    caption: Text? = nil,
    value: Text? = nil,
    accessory: ShadowListAccessory = .none,
    role: ButtonRole? = nil,
    isSelected: Bool = false,
    isEmphasized: Bool = false,
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.init(
      title: title, subtitle: subtitle, caption: caption, value: value, accessory: accessory, role: role, isSelected: isSelected, isEmphasized: isEmphasized,
      hasLeading: true, leading: leading(), trailing: trailing())
  }

  private var phase: ShadowListRowPhase {
    if isSelected { return appearsActive ? .selected : .selectedInactive }
    return isHovered && isEnabled && hoverEffectsEnabled ? .hovered : .standard
  }

  public var body: some View {
    let metrics = ShadowListMetrics()
    let palette = ShadowListRowPalette(density: .current, phase: phase, isDestructive: role == .destructive)
    let inset = metrics.separatorInset(leadingWidth: hasLeading ? leadingWidth : nil)
    HStack(alignment: .center, spacing: metrics.leadingGap) {
      if hasLeading {
        leading.onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { leadingWidth = $0 })
      }
      content(palette: palette, metrics: metrics)
      if accessory == .chevron && metrics.showsChevron {
        Image(systemName: "chevron.forward")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(palette.accessory.color)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, metrics.horizontalPadding)
    .padding(.vertical, metrics.verticalPadding)
    .frame(minHeight: minimumHeight, alignment: .center)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(drawsBackground && phase != .standard ? palette.background.color : Color.clear)
    .overlay(alignment: .bottom) {
      if drawsBackground {
        Rectangle()
          .fill(ShadowColor.borderDefault)
          .frame(height: 1 / displayScale)
          .padding(.leading, inset)
          .offset(y: 1 / displayScale)
      }
    }
    .contentShape(.rect)
    .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .listRowInsets(EdgeInsets())
    .listRowBackground(rowBackground(palette))
    .listRowSeparatorTint(ShadowColor.borderDefault)
    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + inset }
    #if os(macOS)
      .onHover { isHovered = $0 }
    #endif
  }

  @ViewBuilder
  private func rowBackground(_ palette: ShadowListRowPalette) -> some View {
    if ShadowDensity.current == .compact && phase != .standard {
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(palette.background.color)
        .padding(.horizontal, Spacing.space2)
    } else {
      palette.background.color
    }
  }

  @ViewBuilder
  private func content(palette: ShadowListRowPalette, metrics: ShadowListMetrics) -> some View {
    let stacksValue = dynamicTypeSize.isAccessibilitySize && value != nil
    let lineLimit = dynamicTypeSize.isAccessibilitySize ? nil : metrics.textLineLimit
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.space2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.space2))
    layout {
      VStack(alignment: .leading, spacing: Spacing.space05) {
        title
          .shadowFont(.body)
          .fontWeight(isEmphasized ? .semibold : nil)
          .foregroundStyle(palette.title.color)
          .lineLimit(lineLimit)
        if let subtitle {
          subtitle
            .shadowFont(.subheadline)
            .foregroundStyle(palette.secondary.color)
            .lineLimit(lineLimit)
        }
        if let caption {
          caption
            .shadowFont(.footnote)
            .foregroundStyle(palette.secondary.color)
            .lineLimit(lineLimit)
        }
        if stacksValue, let value {
          value
            .shadowFont(.body)
            .foregroundStyle(palette.secondary.color)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .layoutPriority(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      if !stacksValue, let value {
        value
          .shadowFont(.body)
          .foregroundStyle(palette.secondary.color)
          .lineLimit(lineLimit)
          .multilineTextAlignment(.trailing)
      }
      trailing
    }
  }
}

extension ShadowListRow where Trailing == EmptyView {
  public init(
    title: Text, subtitle: Text? = nil, caption: Text? = nil, value: Text? = nil, accessory: ShadowListAccessory = .none, role: ButtonRole? = nil, isSelected: Bool = false,
    isEmphasized: Bool = false, @ViewBuilder leading: () -> Leading
  ) {
    self.init(
      title: title, subtitle: subtitle, caption: caption, value: value, accessory: accessory, role: role, isSelected: isSelected, isEmphasized: isEmphasized,
      hasLeading: true, leading: leading(), trailing: EmptyView())
  }

  public init(
    _ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, caption: LocalizedStringKey? = nil, value: LocalizedStringKey? = nil,
    accessory: ShadowListAccessory = .none, role: ButtonRole? = nil, isSelected: Bool = false, isEmphasized: Bool = false, @ViewBuilder leading: () -> Leading
  ) {
    self.init(
      title: Text(title), subtitle: subtitle.map { Text($0) }, caption: caption.map { Text($0) }, value: value.map { Text($0) }, accessory: accessory, role: role,
      isSelected: isSelected, isEmphasized: isEmphasized, leading: leading)
  }
}

extension ShadowListRow where Leading == EmptyView {
  public init(
    title: Text, subtitle: Text? = nil, caption: Text? = nil, value: Text? = nil, accessory: ShadowListAccessory = .none, role: ButtonRole? = nil, isSelected: Bool = false,
    isEmphasized: Bool = false, trailing: Trailing
  ) {
    self.init(
      title: title, subtitle: subtitle, caption: caption, value: value, accessory: accessory, role: role, isSelected: isSelected, isEmphasized: isEmphasized,
      hasLeading: false, leading: EmptyView(), trailing: trailing)
  }

  public init(
    _ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, caption: LocalizedStringKey? = nil, value: LocalizedStringKey? = nil,
    accessory: ShadowListAccessory = .none, role: ButtonRole? = nil, isSelected: Bool = false, isEmphasized: Bool = false, trailing: Trailing
  ) {
    self.init(
      title: Text(title), subtitle: subtitle.map { Text($0) }, caption: caption.map { Text($0) }, value: value.map { Text($0) }, accessory: accessory, role: role,
      isSelected: isSelected, isEmphasized: isEmphasized, trailing: trailing)
  }
}

extension ShadowListRow where Leading == EmptyView, Trailing == EmptyView {
  public init(
    title: Text, subtitle: Text? = nil, caption: Text? = nil, value: Text? = nil, accessory: ShadowListAccessory = .none, role: ButtonRole? = nil, isSelected: Bool = false,
    isEmphasized: Bool = false
  ) {
    self.init(
      title: title, subtitle: subtitle, caption: caption, value: value, accessory: accessory, role: role, isSelected: isSelected, isEmphasized: isEmphasized,
      hasLeading: false, leading: EmptyView(), trailing: EmptyView())
  }

  public init(
    _ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, caption: LocalizedStringKey? = nil, value: LocalizedStringKey? = nil,
    accessory: ShadowListAccessory = .none, role: ButtonRole? = nil, isSelected: Bool = false, isEmphasized: Bool = false
  ) {
    self.init(
      title: Text(title), subtitle: subtitle.map { Text($0) }, caption: caption.map { Text($0) }, value: value.map { Text($0) }, accessory: accessory, role: role,
      isSelected: isSelected, isEmphasized: isEmphasized)
  }
}

extension ShadowListRow {
  public init(
    _ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, caption: LocalizedStringKey? = nil, value: LocalizedStringKey? = nil,
    accessory: ShadowListAccessory = .none, role: ButtonRole? = nil, isSelected: Bool = false, isEmphasized: Bool = false, @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.init(
      title: Text(title), subtitle: subtitle.map { Text($0) }, caption: caption.map { Text($0) }, value: value.map { Text($0) }, accessory: accessory, role: role,
      isSelected: isSelected, isEmphasized: isEmphasized, leading: leading, trailing: trailing)
  }
}
