import Foundation
import ShadowText

enum DueStanding: String, CaseIterable, Codable, Sendable {
  case notDue = "not_due"
  case due
  case overdue
}

enum PromiseStatus: String, CaseIterable, Codable, Sendable {
  case open
  case closed
  case resolved
  case dropped
}

extension ThreadStatus {
  var promiseStatus: PromiseStatus {
    switch self {
    case .open: .open
    case .closed: .closed
    case .dropped: .dropped
    }
  }
}

extension MysteryStatus {
  var promiseStatus: PromiseStatus {
    switch self {
    case .open: .open
    case .resolved: .resolved
    case .dropped: .dropped
    }
  }
}

struct PromisePayoff: Equatable, Sendable {
  var payoffWindow: Int?
  var payoffMilestoneKey: String?
  var payoffVolumeKey: String?

  init(payoffWindow: Int? = nil, payoffMilestoneKey: String? = nil, payoffVolumeKey: String? = nil) {
    self.payoffWindow = payoffWindow
    self.payoffMilestoneKey = payoffMilestoneKey
    self.payoffVolumeKey = payoffVolumeKey
  }
}

struct PromiseItem: Equatable, Sendable {
  var kind: PromiseKind
  var key: String
  var label: String
  var status: PromiseStatus
  var intentionallyOpen: Bool
  var openedChapter: Int?
  var lastAdvancedChapter: Int?
  var closedChapter: Int?
  var resolvedChapter: Int?
  var payoff: PromisePayoff
  var due: DueStanding
  var createdAt: Date
  var updatedAt: Date
}

struct ThreadRow: Equatable, Sendable {
  var threadKey: String
  var summary: String?
  var status: ThreadStatus
  var intentionallyOpen: Bool
  var openedChapter: Int?
  var closedChapter: Int?
  var lastAdvancedChapter: Int?
  var payoff: PromisePayoff
  var createdAt: Date
  var updatedAt: Date
}

struct MysteryRow: Equatable, Sendable {
  var mysteryKey: String
  var question: String
  var status: MysteryStatus
  var intentionallyOpen: Bool
  var openedChapter: Int?
  var resolvedChapter: Int?
  var lastAdvancedChapter: Int?
  var payoff: PromisePayoff
  var createdAt: Date
  var updatedAt: Date
}

extension Dictionary where Key == JSString {
  /// A JavaScript `Map` built from entries: a repeated key keeps the last value.
  init(jsEntries entries: some Sequence<(key: String, value: Value)>) {
    self.init(entries.map { (JSString($0.key), $0.value) }, uniquingKeysWith: { _, last in last })
  }
}

// apps/novel-forge-server/src/common/promise.ts:32
func resolvePromiseDueStanding(
  _ payoff: PromisePayoff,
  chapter: Int,
  milestoneStates: [JSString: MilestoneState] = [:],
  volumeStates: [JSString: VolumeState] = [:]
) -> DueStanding {
  let dueByChapter = payoff.payoffWindow.map { $0 <= chapter } ?? false
  let dueByMilestone = payoff.payoffMilestoneKey.map { milestoneStates[JSString($0)] == .reached } ?? false
  let volumeState = payoff.payoffVolumeKey.flatMap { volumeStates[JSString($0)] }
  if dueByChapter || volumeState == .goalMet { return .overdue }
  if dueByMilestone || volumeState == .active { return .due }
  return .notDue
}

private func promiseLabel(_ text: String?, fallback: String) -> String {
  guard let trimmed = text?.jsTrim(), !trimmed.isEmpty else { return fallback }
  return trimmed
}

// apps/novel-forge-server/src/common/promise.ts:78
func threadPromiseItem(
  _ thread: ThreadRow,
  chapter: Int,
  milestoneStates: [JSString: MilestoneState] = [:],
  volumeStates: [JSString: VolumeState] = [:]
) -> PromiseItem {
  PromiseItem(
    kind: .thread,
    key: thread.threadKey,
    label: promiseLabel(thread.summary, fallback: thread.threadKey),
    status: thread.status.promiseStatus,
    intentionallyOpen: thread.intentionallyOpen,
    openedChapter: thread.openedChapter,
    lastAdvancedChapter: thread.lastAdvancedChapter,
    closedChapter: thread.closedChapter,
    resolvedChapter: nil,
    payoff: thread.payoff,
    due: resolvePromiseDueStanding(thread.payoff, chapter: chapter, milestoneStates: milestoneStates, volumeStates: volumeStates),
    createdAt: thread.createdAt,
    updatedAt: thread.updatedAt
  )
}

// apps/novel-forge-server/src/common/promise.ts:104
func mysteryPromiseItem(
  _ mystery: MysteryRow,
  chapter: Int,
  milestoneStates: [JSString: MilestoneState] = [:],
  volumeStates: [JSString: VolumeState] = [:]
) -> PromiseItem {
  PromiseItem(
    kind: .mystery,
    key: mystery.mysteryKey,
    label: promiseLabel(mystery.question, fallback: mystery.mysteryKey),
    status: mystery.status.promiseStatus,
    intentionallyOpen: mystery.intentionallyOpen,
    openedChapter: mystery.openedChapter,
    lastAdvancedChapter: mystery.lastAdvancedChapter,
    closedChapter: nil,
    resolvedChapter: mystery.resolvedChapter,
    payoff: mystery.payoff,
    due: resolvePromiseDueStanding(mystery.payoff, chapter: chapter, milestoneStates: milestoneStates, volumeStates: volumeStates),
    createdAt: mystery.createdAt,
    updatedAt: mystery.updatedAt
  )
}
