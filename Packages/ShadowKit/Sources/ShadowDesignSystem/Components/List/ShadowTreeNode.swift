import SwiftUI

nonisolated public struct ShadowTreeNode<ID: Hashable & Sendable>: Identifiable, Hashable, Sendable {
  public let id: ID
  public let title: String
  public let systemImage: String
  public let accessorySystemImage: String?
  public let children: [ShadowTreeNode<ID>]?

  public init(id: ID, title: String, systemImage: String, accessorySystemImage: String? = nil, children: [ShadowTreeNode<ID>]? = nil) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
    self.accessorySystemImage = accessorySystemImage
    self.children = children
  }

  public var isLeaf: Bool { children == nil }

  public var descendantCount: Int {
    (children ?? []).reduce(0) { $0 + 1 + $1.descendantCount }
  }

  public var depth: Int {
    1 + ((children ?? []).map(\.depth).max() ?? 0)
  }

  public func flattened(level: Int = 0) -> [(node: ShadowTreeNode<ID>, level: Int)] {
    [(self, level)] + (children ?? []).flatMap { $0.flattened(level: level + 1) }
  }

  public func node(withID target: ID) -> ShadowTreeNode<ID>? {
    flattened().first { $0.node.id == target }?.node
  }
}
