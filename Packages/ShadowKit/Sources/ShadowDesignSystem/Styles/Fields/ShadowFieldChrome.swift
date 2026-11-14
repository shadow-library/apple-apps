import SwiftUI

struct ShadowFieldChrome<Leading: View, Trailing: View>: ViewModifier {
  let kind: ShadowFieldKind
  let leading: Leading
  let trailing: Trailing
  var isInvalid = false
  var externalFocus: Bool?

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.shadowValidationMessage) private var message
  @Environment(\.shadowPreviewFieldFocus) private var previewFocus
  @Environment(\.colorSchemeContrast) private var contrast
  @FocusState private var isFocused: Bool

  private var metrics: ShadowFieldMetrics { ShadowFieldMetrics(kind: kind) }
  private var hasAccessories: Bool { Leading.self != EmptyView.self || Trailing.self != EmptyView.self }

  private var phase: ShadowFieldPhase {
    ShadowFieldPhase(isFocused: previewFocus ?? externalFocus ?? isFocused, isInvalid: isInvalid || message != nil)
  }

  func body(content: Content) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      field(content)
      if let message { ShadowValidationMessage(message) }
    }
  }

  @ViewBuilder
  private func field(_ content: Content) -> some View {
    let metrics = metrics
    if metrics.usesNativeBezel && !hasAccessories {
      content
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .modifier(ShadowOwnFocus(isExternal: externalFocus != nil, binding: $isFocused))
        .overlay { if phase.isInvalid { invalidRing(metrics) } }
    } else {
      HStack(alignment: kind == .multiline ? .top : .center, spacing: metrics.accessorySpacing) {
        leading.foregroundStyle(ShadowColor.textSecondary)
        content
          .textFieldStyle(.plain)
          .modifier(ShadowOwnFocus(isExternal: externalFocus != nil, binding: $isFocused))
          .frame(maxWidth: .infinity, alignment: .leading)
        trailing.foregroundStyle(ShadowColor.textSecondary)
      }
      .padding(.horizontal, metrics.horizontalPadding)
      .padding(.vertical, metrics.verticalPadding)
      .frame(minHeight: metrics.minHeight, alignment: kind == .multiline ? .top : .center)
      .background { chrome(metrics) }
      .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
      .contentShape(.rect)
      .onTapGesture { if externalFocus == nil { isFocused = true } }
    }
  }

  private func shape(_ metrics: ShadowFieldMetrics) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
  }

  private func chrome(_ metrics: ShadowFieldMetrics) -> some View {
    let shape = shape(metrics)
    return
      shape
      .fill(fill(metrics))
      .overlay { shape.strokeBorder(border(metrics), lineWidth: metrics.borderWidth) }
      .overlay {
        if phase.showsHalo {
          shape
            .inset(by: -metrics.haloWidth / 2)
            .stroke(phase.isInvalid ? ShadowColor.focusFieldRingError : ShadowColor.focusFieldRing, lineWidth: metrics.haloWidth)
            .allowsHitTesting(false)
        }
      }
  }

  private func invalidRing(_ metrics: ShadowFieldMetrics) -> some View {
    let shape = RoundedRectangle(cornerRadius: Radius.md + 1, style: .continuous)
    return ZStack {
      shape.inset(by: -metrics.haloWidth / 2).stroke(ShadowColor.focusFieldRingError, lineWidth: metrics.haloWidth)
      shape.strokeBorder(ShadowColor.dangerSolid, lineWidth: metrics.borderWidth)
    }
    .allowsHitTesting(false)
  }

  private func fill(_ metrics: ShadowFieldMetrics) -> Color {
    if phase.isFocused { return ShadowColor.surfaceCard }
    switch (metrics.density, kind) {
    case (.touch, _): return ShadowColor.surfaceWell
    case (.compact, .search): return ShadowColor.surfaceWell
    case (.compact, _): return ShadowColor.surfaceCard
    }
  }

  private func border(_ metrics: ShadowFieldMetrics) -> Color {
    if phase.isInvalid { return ShadowColor.dangerSolid }
    if phase.isFocused { return ShadowColor.borderFocus }
    if metrics.density == .compact || contrast == .increased { return ShadowColor.borderDefault }
    return .clear
  }
}

private struct ShadowOwnFocus: ViewModifier {
  let isExternal: Bool
  var binding: FocusState<Bool>.Binding

  @ViewBuilder
  func body(content: Content) -> some View {
    if isExternal {
      content
    } else {
      content.focused(binding)
    }
  }
}

extension View {
  public func shadowField(isFocused: Bool? = nil) -> some View {
    modifier(ShadowFieldChrome(kind: .text, leading: EmptyView(), trailing: EmptyView(), externalFocus: isFocused))
  }

  public func shadowField<Trailing: View>(isFocused: Bool? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
    modifier(ShadowFieldChrome(kind: .text, leading: EmptyView(), trailing: trailing(), externalFocus: isFocused))
  }

  public func shadowField<Leading: View, Trailing: View>(
    isFocused: Bool? = nil,
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    modifier(ShadowFieldChrome(kind: .text, leading: leading(), trailing: trailing(), externalFocus: isFocused))
  }

  func shadowFieldChrome<Leading: View, Trailing: View>(kind: ShadowFieldKind, leading: Leading, trailing: Trailing, isInvalid: Bool = false) -> some View {
    modifier(ShadowFieldChrome(kind: kind, leading: leading, trailing: trailing, isInvalid: isInvalid))
  }
}
