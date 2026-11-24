import MemoirCore
import ShadowStore

struct InsightSections: Equatable {
  let quests: Bool
  let hero: Bool
  let money: Bool
  let body: Bool

  init(_ selection: ModuleSelection) {
    quests = selection.contains(.quests)
    hero = selection.contains(.hero)
    money = selection.contains(.money)
    body = selection.contains(.body)
  }

  var isEmpty: Bool { !(quests || hero || money || body) }
}

extension ReviewStep {
  var position: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

extension ModuleSelection {
  var historyKinds: Set<HistoryKind> {
    var kinds = Set<HistoryKind>()
    if contains(.quests) { kinds.formUnion([.quest, .recovery, .sideQuest]) }
    if contains(.hero) { kinds.insert(.hero) }
    if contains(.money) { kinds.insert(.expense) }
    if contains(.journal) { kinds.insert(.journal) }
    if contains(.meals) { kinds.insert(.meal) }
    if contains(.body) { kinds.formUnion([.weight, .health]) }
    return kinds
  }

  var reviewSteps: [ReviewStep] {
    ReviewStep.allCases.filter { step in
      switch step {
      case .kept: contains(.quests)
      case .money: contains(.money)
      case .body: contains(.body)
      case .reflect, .done: true
      }
    }
  }

  func readableBodyClasses(_ classes: Set<SyncClass>) -> Set<SyncClass> {
    contains(.body) ? classes : []
  }
}
