import SwiftUI

nonisolated public enum ShadowFieldKind: Hashable, Sendable, CaseIterable {
  case text
  case search
  case multiline
}

nonisolated public enum ShadowFieldPhase: Hashable, Sendable, CaseIterable {
  case idle
  case focused
  case invalid
  case focusedInvalid

  public init(isFocused: Bool, isInvalid: Bool) {
    switch (isFocused, isInvalid) {
    case (false, false): self = .idle
    case (true, false): self = .focused
    case (false, true): self = .invalid
    case (true, true): self = .focusedInvalid
    }
  }

  public var isInvalid: Bool { self == .invalid || self == .focusedInvalid }
  public var isFocused: Bool { self == .focused || self == .focusedInvalid }
  public var showsHalo: Bool { self != .idle }
}

nonisolated public struct ShadowFieldMetrics: Hashable, Sendable {
  public let density: ShadowDensity
  public let kind: ShadowFieldKind

  public init(density: ShadowDensity = .current, kind: ShadowFieldKind = .text) {
    self.density = density
    self.kind = kind
  }

  public var minHeight: CGFloat {
    density.controlHeight(.medium) * (kind == .multiline ? 3 : 1)
  }

  public var cornerRadius: CGFloat {
    switch (density, kind) {
    case (.touch, .search): Radius.full
    case (.touch, _): Radius.xl
    case (.compact, _): Radius.md
    }
  }

  public var horizontalPadding: CGFloat { density == .touch ? Spacing.space4 : Spacing.space2 }
  public var verticalPadding: CGFloat { kind == .multiline ? Spacing.space1 : 0 }
  public var accessorySpacing: CGFloat { Spacing.space2 }
  public var haloWidth: CGFloat { 3 }
  public var borderWidth: CGFloat { 1 }
  public var usesNativeBezel: Bool { density == .compact && kind == .text }
}

nonisolated public struct ShadowCharacterCount: Hashable, Sendable {
  public let count: Int
  public let limit: Int?

  public init(count: Int, limit: Int? = nil) {
    self.count = max(count, 0)
    self.limit = limit.map { max($0, 0) }
  }

  public init(text: String, limit: Int? = nil) {
    self.init(count: text.count, limit: limit)
  }

  public var remaining: Int? { limit.map { $0 - count } }
  public var isOverLimit: Bool { (remaining ?? 0) < 0 }
}
