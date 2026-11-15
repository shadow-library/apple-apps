import Foundation
import SwiftUI

nonisolated public enum ShadowToastDuration: Hashable, Sendable {
  case automatic
  case seconds(Double)
  case persistent
}

nonisolated public enum ShadowToastPlacement: Hashable, Sendable, CaseIterable {
  case automatic
  case top
  case bottom

  public func edge(for density: ShadowDensity) -> VerticalEdge {
    switch self {
    case .automatic: density == .touch ? .top : .bottom
    case .top: .top
    case .bottom: .bottom
    }
  }
}

nonisolated public struct ShadowToastButton: Sendable {
  public let title: LocalizedStringResource
  public let perform: @MainActor @Sendable () -> Void

  public init(_ title: LocalizedStringResource, perform: @escaping @MainActor @Sendable () -> Void) {
    self.title = title
    self.perform = perform
  }
}

nonisolated public struct ShadowToast: Identifiable, Sendable {
  public let id: String
  public let message: LocalizedStringResource
  public let systemImage: String?
  public let intent: ShadowIntent
  public let action: ShadowToastButton?
  public let dismissLabel: LocalizedStringResource?
  public let duration: ShadowToastDuration

  public init(
    _ message: LocalizedStringResource,
    systemImage: String? = nil,
    intent: ShadowIntent = .neutral,
    action: ShadowToastButton? = nil,
    dismissLabel: LocalizedStringResource? = nil,
    duration: ShadowToastDuration = .automatic,
    id: String = UUID().uuidString
  ) {
    self.id = id
    self.message = message
    self.systemImage = systemImage
    self.intent = intent
    self.action = action
    self.dismissLabel = dismissLabel
    self.duration = duration
  }

  public var announcement: String {
    [String(localized: message), action.map { String(localized: $0.title) }].compactMap(\.self).joined(separator: ", ")
  }

  public func visibleDuration(isVoiceOverRunning: Bool) -> Duration? {
    ShadowToastTiming.duration(
      characterCount: String(localized: message).count, hasAction: action != nil, requested: duration, isVoiceOverRunning: isVoiceOverRunning)
  }
}

nonisolated public enum ShadowToastTiming {
  public static let minimum: Duration = .seconds(4)
  public static let minimumWithAction: Duration = .seconds(6)
  public static let maximum: Duration = .seconds(10)
  public static let voiceOverFactor = 2
  public static let resumeGrace: Duration = .seconds(2)
  static let baseReadingTime: Duration = .seconds(2)
  static let charactersPerSecond = 15

  public static func duration(characterCount: Int, hasAction: Bool, requested: ShadowToastDuration, isVoiceOverRunning: Bool) -> Duration? {
    let visible: Duration
    switch requested {
    case .persistent:
      return nil
    case .seconds(let seconds):
      guard seconds.isFinite else { return nil }
      visible = .seconds(max(seconds, 1))
    case .automatic:
      let reading = baseReadingTime + .seconds(Double(max(characterCount, 0)) / Double(charactersPerSecond))
      visible = min(max(reading, hasAction ? minimumWithAction : minimum), maximum)
    }
    return isVoiceOverRunning ? visible * voiceOverFactor : visible
  }
}

nonisolated public struct ShadowToastQueue: Sendable {
  public private(set) var current: ShadowToast?
  public private(set) var pending: [ShadowToast] = []

  public init() {}

  public var isEmpty: Bool { current == nil && pending.isEmpty }

  @discardableResult
  public mutating func enqueue(_ toast: ShadowToast) -> Bool {
    guard !contains(toast.id) else { return false }
    if current == nil && pending.isEmpty {
      current = toast
    } else {
      pending.append(toast)
    }
    return true
  }

  @discardableResult
  public mutating func dismiss(id: ShadowToast.ID) -> Bool {
    if current?.id == id {
      current = nil
      return true
    }
    pending.removeAll { $0.id == id }
    return false
  }

  @discardableResult
  public mutating func advance() -> ShadowToast? {
    guard current == nil, !pending.isEmpty else { return nil }
    current = pending.removeFirst()
    return current
  }

  public mutating func removeAll() {
    current = nil
    pending.removeAll()
  }

  public func contains(_ id: ShadowToast.ID) -> Bool {
    current?.id == id || pending.contains { $0.id == id }
  }
}

nonisolated struct ShadowToastCountdown: Equatable, Sendable {
  enum PauseReason: Hashable, Sendable {
    case hover
    case focus
    case accessibilityFocus
    case drag
  }

  private(set) var remaining: Duration
  private(set) var resumedAt: ContinuousClock.Instant?
  private(set) var pauseReasons: Set<PauseReason> = []

  init(duration: Duration, startingAt now: ContinuousClock.Instant) {
    remaining = duration
    resumedAt = now
  }

  var isRunning: Bool { resumedAt != nil }

  var deadline: ContinuousClock.Instant? { resumedAt.map { $0 + remaining } }

  func remaining(at now: ContinuousClock.Instant) -> Duration {
    guard let resumedAt else { return remaining }
    return max(remaining - (now - resumedAt), .zero)
  }

  mutating func pause(_ reason: PauseReason, at now: ContinuousClock.Instant) {
    if pauseReasons.isEmpty {
      remaining = remaining(at: now)
      resumedAt = nil
    }
    pauseReasons.insert(reason)
  }

  mutating func resume(_ reason: PauseReason, at now: ContinuousClock.Instant) {
    guard pauseReasons.remove(reason) != nil, pauseReasons.isEmpty else { return }
    remaining = max(remaining, ShadowToastTiming.resumeGrace)
    resumedAt = now
  }
}
