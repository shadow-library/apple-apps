import SwiftUI

nonisolated public enum ShadowAvatarSize: Hashable, Sendable, CaseIterable {
  case extraSmall
  case small
  case medium
  case large

  public var diameter: CGFloat {
    switch self {
    case .extraSmall: 22
    case .small: 28
    case .medium: 40
    case .large: 64
    }
  }

  var textStyle: Font.TextStyle {
    switch self {
    case .extraSmall, .small: .caption
    case .medium: .body
    case .large: .title
    }
  }
}

nonisolated public enum ShadowAvatarKind: Hashable, Sendable, CaseIterable {
  case person
  case organization

  var placeholderSystemImage: String {
    self == .person ? "person.fill" : "building.2.fill"
  }
}

nonisolated public enum ShadowAvatarPresence: Hashable, Sendable, CaseIterable {
  case online
  case away
  case busy
  case offline
}

public enum ShadowAvatarSource {
  case initials
  case image(Image)
  case url(URL)
}

public struct ShadowAvatar: View {
  private let name: String
  private let id: String?
  private let kind: ShadowAvatarKind
  private let size: ShadowAvatarSize
  private let tint: ShadowAvatarTint?
  private let source: ShadowAvatarSource
  private let presence: ShadowAvatarPresence?
  private let presenceLabel: Text?
  private let ring: Color
  var textScale: CGFloat = 0.38

  public init(
    name: String,
    id: String? = nil,
    kind: ShadowAvatarKind = .person,
    size: ShadowAvatarSize = .medium,
    tint: ShadowAvatarTint? = nil,
    source: ShadowAvatarSource = .initials,
    presence: ShadowAvatarPresence? = nil,
    presenceLabel: Text? = nil,
    ring: Color = ShadowColor.surfaceCard
  ) {
    self.name = name
    self.id = id
    self.kind = kind
    self.size = size
    self.tint = tint
    self.source = source
    self.presence = presence
    self.presenceLabel = presenceLabel
    self.ring = ring
  }

  public var body: some View {
    ShadowAvatarBody(name: name, id: id, kind: kind, size: size, tint: tint, source: source, presence: presence, ring: ring, textScale: textScale)
      .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: name))
      .accessibilityValue(presence == nil ? Text(verbatim: "") : presenceLabel ?? Text(verbatim: ""))
      .accessibilityAddTraits(.isImage)
  }
}

private struct ShadowAvatarBody: View {
  let name: String
  let id: String?
  let kind: ShadowAvatarKind
  let size: ShadowAvatarSize
  let tint: ShadowAvatarTint?
  let source: ShadowAvatarSource
  let presence: ShadowAvatarPresence?
  let ring: Color
  let textScale: CGFloat

  @Environment(\.isEnabled) private var isEnabled
  @ScaledMetric private var diameter: CGFloat

  init(
    name: String, id: String?, kind: ShadowAvatarKind, size: ShadowAvatarSize, tint: ShadowAvatarTint?, source: ShadowAvatarSource, presence: ShadowAvatarPresence?,
    ring: Color, textScale: CGFloat
  ) {
    self.textScale = textScale
    self.name = name
    self.id = id
    self.kind = kind
    self.size = size
    self.tint = tint
    self.source = source
    self.presence = presence
    self.ring = ring
    _diameter = ScaledMetric(wrappedValue: size.diameter, relativeTo: size.textStyle)
  }

  private var initials: String { ShadowInitials.make(from: name) }

  private var resolvedTint: ShadowAvatarTint {
    if initials.isEmpty { return .neutral }
    if let tint { return tint }
    return kind == .organization ? .solid : .automatic(for: id ?? name)
  }

  var body: some View {
    face
      .frame(width: diameter, height: diameter)
      .clipShape(.circle)
      .overlay(alignment: .bottomTrailing) {
        if let presence { ShadowPresenceDot(presence: presence, diameter: diameter, ring: ring) }
      }
      .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
  }

  @ViewBuilder
  private var face: some View {
    switch source {
    case .initials: fallback
    case .image(let image): image.resizable().scaledToFill()
    case .url(let url):
      AsyncImage(url: url) { phase in
        if let image = phase.image {
          image.resizable().scaledToFill()
        } else {
          fallback
        }
      }
    }
  }

  private var fallback: some View {
    let tint = resolvedTint
    return ZStack {
      tint.background
      if initials.isEmpty {
        Image(systemName: kind.placeholderSystemImage)
          .font(.system(size: diameter * 0.46, weight: .regular))
          .foregroundStyle(tint.foreground)
      } else {
        Text(verbatim: initials)
          .font(.system(size: diameter * textScale, weight: .semibold))
          .foregroundStyle(tint.foreground)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
      }
    }
  }
}

private struct ShadowPresenceDot: View {
  let presence: ShadowAvatarPresence
  let diameter: CGFloat
  let ring: Color

  private static let ringWidth: CGFloat = 2
  private var dot: CGFloat { max(diameter * 0.28, 7) }

  var body: some View {
    ZStack {
      Circle().fill(ring)
      Circle().fill(fill).padding(Self.ringWidth)
      if presence == .offline { Circle().fill(ring).padding(Self.ringWidth * 2) }
      if presence == .busy, dot >= 11 {
        Capsule().fill(ShadowColor.dangerOnSolid).frame(width: dot * 0.45, height: 1.5)
      }
    }
    .frame(width: dot + Self.ringWidth * 2, height: dot + Self.ringWidth * 2)
    .offset(x: Self.ringWidth, y: Self.ringWidth)
    .accessibilityHidden(true)
  }

  private var fill: Color {
    switch presence {
    case .online: ShadowColor.successSolid
    case .away: ShadowColor.warningSolid
    case .busy: ShadowColor.dangerSolid
    case .offline: ShadowColor.neutralSolid
    }
  }
}

extension ShadowAvatar {
  func initialsScale(_ scale: CGFloat) -> ShadowAvatar {
    var copy = self
    copy.textScale = scale
    return copy
  }
}
