import SwiftUI

struct ShadowFieldSurface: View {
  let phase: ShadowFieldPhase
  let metrics: ShadowFieldMetrics
  var cornerRadius: CGFloat?

  @Environment(\.colorSchemeContrast) private var contrast

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius ?? metrics.cornerRadius, style: .continuous)
  }

  var body: some View {
    shape
      .fill(fill)
      .overlay { shape.strokeBorder(border, lineWidth: metrics.borderWidth) }
      .overlay {
        if phase.showsHalo {
          shape
            .inset(by: -metrics.haloWidth / 2)
            .stroke(phase.isInvalid ? ShadowColor.focusFieldRingError : ShadowColor.focusFieldRing, lineWidth: metrics.haloWidth)
            .allowsHitTesting(false)
        }
      }
  }

  private var fill: Color {
    if phase.isFocused { return ShadowColor.surfaceCard }
    switch (metrics.density, metrics.kind) {
    case (.touch, _): return ShadowColor.surfaceWell
    case (.compact, .search): return ShadowColor.surfaceWell
    case (.compact, _): return ShadowColor.surfaceCard
    }
  }

  private var border: Color {
    if phase.isInvalid { return ShadowColor.dangerSolid }
    if phase.isFocused { return ShadowColor.borderFocus }
    if metrics.density == .compact || contrast == .increased { return ShadowColor.borderDefault }
    return .clear
  }
}
