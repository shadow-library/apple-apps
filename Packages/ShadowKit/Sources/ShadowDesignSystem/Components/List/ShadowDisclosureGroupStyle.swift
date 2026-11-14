import SwiftUI

public struct ShadowDisclosureGroupStyle: DisclosureGroupStyle {
  private let expandedValue: Text?
  private let collapsedValue: Text?

  public init(expandedValue: Text? = nil, collapsedValue: Text? = nil) {
    self.expandedValue = expandedValue
    self.collapsedValue = collapsedValue
  }

  public func makeBody(configuration: Configuration) -> some View {
    ShadowDisclosureBody(configuration: configuration, expandedValue: expandedValue, collapsedValue: collapsedValue)
  }
}

extension DisclosureGroupStyle where Self == ShadowDisclosureGroupStyle {
  public static var shadow: Self { Self() }

  public static func shadow(expandedValue: Text, collapsedValue: Text) -> Self {
    Self(expandedValue: expandedValue, collapsedValue: collapsedValue)
  }
}

private struct ShadowDisclosureBody: View {
  let configuration: DisclosureGroupStyleConfiguration
  let expandedValue: Text?
  let collapsedValue: Text?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.displayScale) private var displayScale
  @Environment(\.shadowDrawsRowBackground) private var isInGroupedSection
  @ScaledMetric(relativeTo: .body) private var minimumHeight = ShadowListMetrics().minimumRowHeight

  private var collapsedRotation: Angle { .degrees(layoutDirection == .rightToLeft ? 90 : -90) }

  var body: some View {
    let metrics = ShadowListMetrics()
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.shadow(.normal, reduceMotion: reduceMotion)) { configuration.isExpanded.toggle() }
      } label: {
        HStack(spacing: Spacing.space2) {
          configuration.label
            .shadowFont(.body)
            .fontWeight(.semibold)
            .foregroundStyle(ShadowColor.textPrimary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "chevron.down")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ShadowColor.textTertiary)
            .rotationEffect(configuration.isExpanded ? .zero : collapsedRotation)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
        .frame(minHeight: minimumHeight)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityValue(configuration.isExpanded ? expandedValue ?? Text(verbatim: "") : collapsedValue ?? Text(verbatim: ""))
      if configuration.isExpanded {
        Rectangle()
          .fill(ShadowColor.borderDefault)
          .frame(height: 1 / displayScale)
          .padding(.leading, metrics.horizontalPadding)
        configuration.content
          .shadowFont(.body)
          .foregroundStyle(ShadowColor.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, metrics.horizontalPadding)
          .padding(.vertical, metrics.verticalPadding + Spacing.space05)
          .shadowTransition(.opacity)
      }
    }
    .overlay(alignment: .bottom) {
      if isInGroupedSection {
        Rectangle()
          .fill(ShadowColor.borderDefault)
          .frame(height: 1 / displayScale)
          .padding(.leading, metrics.horizontalPadding)
          .offset(y: 1 / displayScale)
      }
    }
    .listRowInsets(EdgeInsets())
    .listRowBackground(ShadowColor.surfaceCard)
  }
}
