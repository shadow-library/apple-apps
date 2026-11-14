import SwiftUI

public struct ShadowSwatch<ID: Hashable & Sendable>: Identifiable {
  public let id: ID
  public let color: Color
  public let label: LocalizedStringKey

  public init(id: ID, color: Color, label: LocalizedStringKey) {
    self.id = id
    self.color = color
    self.label = label
  }
}

public struct ShadowSwatchPicker<ID: Hashable & Sendable>: View {
  @Binding private var selection: ID
  private let swatches: [ShadowSwatch<ID>]

  @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 28

  public init(selection: Binding<ID>, swatches: [ShadowSwatch<ID>]) {
    _selection = selection
    self.swatches = swatches
  }

  public var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: max(diameter + Spacing.space4, ShadowMetrics.tapTarget)), spacing: 0)], spacing: 0) {
      ForEach(swatches) { swatch in
        Button {
          selection = swatch.id
        } label: {
          Circle()
            .fill(swatch.color)
            .frame(width: diameter, height: diameter)
            .padding(Spacing.space1)
            .overlay {
              if swatch.id == selection { Circle().strokeBorder(ShadowColor.focusRing, lineWidth: 2) }
            }
            .frame(minWidth: ShadowMetrics.tapTarget, minHeight: ShadowMetrics.tapTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.label)
        .accessibilityAddTraits(swatch.id == selection ? .isSelected : [])
      }
    }
    .accessibilityElement(children: .contain)
  }
}
