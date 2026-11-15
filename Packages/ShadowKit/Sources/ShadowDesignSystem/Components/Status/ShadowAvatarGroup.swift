import SwiftUI

public struct ShadowAvatarMember: Identifiable {
  public let id: String
  public let name: String
  public let source: ShadowAvatarSource

  public init(id: String, name: String, source: ShadowAvatarSource = .initials) {
    self.id = id
    self.name = name
    self.source = source
  }
}

nonisolated public struct ShadowAvatarGroupLayout: Hashable, Sendable {
  public let visibleCount: Int
  public let overflow: Int

  public init(total: Int, maximumVisible: Int) {
    let total = max(total, 0)
    let maximumVisible = max(maximumVisible, 1)
    let hidden = total - maximumVisible
    visibleCount = hidden > 1 ? maximumVisible : total
    overflow = hidden > 1 ? hidden : 0
  }

  public static let overflowCap = 99

  public var overflowText: String {
    overflow > Self.overflowCap ? "\(Self.overflowCap)+" : "+\(overflow)"
  }
}

public struct ShadowAvatarGroup: View {
  private let members: [ShadowAvatarMember]
  private let totalCount: Int
  private let maximumVisible: Int
  private let size: ShadowAvatarSize
  private let summary: Text?
  private let ring: Color

  public init(
    _ members: [ShadowAvatarMember], totalCount: Int? = nil, maximumVisible: Int = 3, size: ShadowAvatarSize = .small, summary: Text? = nil,
    ring: Color = ShadowColor.surfaceCard
  ) {
    self.members = members
    self.totalCount = max(totalCount ?? members.count, members.count)
    self.maximumVisible = maximumVisible
    self.size = size
    self.summary = summary
    self.ring = ring
  }

  private static let ringWidth: CGFloat = 2
  private static let overlapRatio: CGFloat = 0.15

  private var layout: ShadowAvatarGroupLayout { ShadowAvatarGroupLayout(total: totalCount, maximumVisible: maximumVisible) }

  public var body: some View {
    let layout = layout
    HStack(spacing: -(size.diameter * Self.overlapRatio + Self.ringWidth * 2)) {
      ForEach(members.prefix(layout.visibleCount)) { member in
        ShadowAvatar(name: member.name, id: member.id, size: size, source: member.source, ring: ring)
          .initialsScale(0.32)
          .ringed(ring)
      }
      if layout.overflow > 0 { ShadowAvatarOverflow(text: layout.overflowText, size: size, ring: ring) }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(summary ?? Text(verbatim: accessibilityNames(overflow: layout.overflow)))
  }

  private func accessibilityNames(overflow: Int) -> String {
    let names = members.prefix(layout.visibleCount).map(\.name).joined(separator: ", ")
    return overflow > 0 ? "\(names) +\(overflow)" : names
  }
}

private struct ShadowAvatarOverflow: View {
  let text: String
  let size: ShadowAvatarSize
  let ring: Color

  @ScaledMetric private var diameter: CGFloat

  init(text: String, size: ShadowAvatarSize, ring: Color) {
    self.text = text
    self.size = size
    self.ring = ring
    _diameter = ScaledMetric(wrappedValue: size.diameter, relativeTo: size.textStyle)
  }

  var body: some View {
    Text(verbatim: text)
      .font(.system(size: diameter * 0.38, weight: .semibold))
      .monospacedDigit()
      .lineLimit(1)
      .foregroundStyle(ShadowAvatarTint.neutral.foreground)
      .padding(.horizontal, diameter * 0.2)
      .frame(minWidth: diameter, minHeight: diameter)
      .fixedSize()
      .background(ShadowAvatarTint.neutral.background, in: .circle)
      .ringed(ring)
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
  }
}

extension View {
  fileprivate func ringed(_ color: Color) -> some View {
    padding(2).background(color, in: .circle)
  }
}
