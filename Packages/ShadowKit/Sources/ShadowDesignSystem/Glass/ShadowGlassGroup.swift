import SwiftUI

public struct ShadowGlassGroup<Content: View>: View {
  private let spacing: CGFloat?
  private let content: Content

  public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  public var body: some View {
    #if os(visionOS)
      content
    #else
      GlassEffectContainer(spacing: spacing) { content }
    #endif
  }
}

extension View {
  public func shadowGlassID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
    #if os(visionOS)
      matchedGeometryEffect(id: id, in: namespace)
    #else
      glassEffectID(id, in: namespace)
    #endif
  }

  public func shadowGlassUnion(id: some Hashable & Sendable, namespace: Namespace.ID) -> some View {
    #if os(visionOS)
      self
    #else
      glassEffectUnion(id: id, namespace: namespace)
    #endif
  }
}
