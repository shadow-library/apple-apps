import CoreGraphics

nonisolated public struct ShadowScalarToken: Hashable, Sendable, Identifiable {
  public let name: String
  public let value: CGFloat

  public var id: String { name }
}
