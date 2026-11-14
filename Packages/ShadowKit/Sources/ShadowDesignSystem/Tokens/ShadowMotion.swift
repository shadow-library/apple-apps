import SwiftUI

nonisolated public enum ShadowMotion: Sendable, CaseIterable {
  case fast
  case normal
  case emphasized

  var duration: TimeInterval {
    switch self {
    case .fast: 0.15
    case .normal: 0.2
    case .emphasized: 0.35
    }
  }

  var spring: Animation {
    switch self {
    case .fast: .snappy
    case .normal: .smooth
    case .emphasized: .bouncy(duration: duration)
    }
  }
}

nonisolated extension Animation {
  public static func shadow(_ motion: ShadowMotion, reduceMotion: Bool = false) -> Animation {
    reduceMotion ? .easeInOut(duration: motion.duration) : motion.spring
  }
}

private struct ShadowAnimationModifier<Value: Equatable>: ViewModifier {
  let motion: ShadowMotion
  let value: Value
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.animation(.shadow(motion, reduceMotion: reduceMotion), value: value)
  }
}

private struct ShadowTransitionModifier: ViewModifier {
  let transition: AnyTransition
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.transition(reduceMotion ? .opacity : transition)
  }
}

extension View {
  public func shadowAnimation(_ motion: ShadowMotion, value: some Equatable) -> some View {
    modifier(ShadowAnimationModifier(motion: motion, value: value))
  }

  public func shadowTransition(_ transition: some Transition) -> some View {
    modifier(ShadowTransitionModifier(transition: AnyTransition(transition)))
  }
}
