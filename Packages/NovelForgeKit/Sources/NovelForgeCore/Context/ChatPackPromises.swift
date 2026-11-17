// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts
extension ChatPack {
  private enum Standing: String {
    case due
    case dormant
    case open
    case onPurpose = "dormant on purpose"
  }

  private static let standingOrder: [Standing] = [.due, .dormant, .open, .onPurpose]

  // dormant-threads.ts:4
  private static let dormantThresholdChapters = 6

  /// The promises `computeDormantThreads` flags as `dormant` at `currentChapter`; an overdue one is reported as overdue, never as dormant.
  // dormant-threads.ts:27
  private static func dormantRefs(_ promises: [ChatPackPromise], currentChapter: Int) -> Set<JSString> {
    var refs = Set<JSString>()
    for promise in promises where promise.isOpen && !promise.intentionallyOpen {
      let overdue = promise.payoffWindow.map { currentChapter > $0 } ?? false
      let staleness = currentChapter - (promise.lastAdvancedChapter ?? promise.openedChapter ?? 0)
      if !overdue && staleness > dormantThresholdChapters { refs.insert(JSString("\(promise.kind.rawValue):\(promise.key)")) }
    }
    return refs
  }

  // novel-chat-context.ts:269
  static func payoffLabel(window: Int?, milestoneKey: String?, volumeKey: String?) -> String {
    if let milestoneKey = present(milestoneKey) { return "milestone \(milestoneKey)" }
    if let volumeKey = present(volumeKey) { return "volume \(volumeKey)" }
    if let window { return "ch \(window)" }
    return "someday"
  }

  // novel-chat-context.ts:299
  static func renderPromises(
    _ promises: [ChatPackPromise], nextChapter: Int, milestoneStates: [JSString: MilestoneState] = [:], volumeStates: [JSString: VolumeState] = [:]
  ) -> String {
    let ordered = promises.filter { $0.kind == .thread } + promises.filter { $0.kind == .mystery }
    let dormant = dormantRefs(ordered, currentChapter: max(nextChapter - 1, 0))
    func standing(of promise: ChatPackPromise, ref: String) -> Standing {
      if promise.intentionallyOpen { return .onPurpose }
      let dueByChapter = promise.payoffWindow.map { $0 <= nextChapter } ?? false
      let dueByMilestone = present(promise.payoffMilestoneKey).map { milestoneStates[JSString($0)] == .reached } ?? false
      let volumeState = present(promise.payoffVolumeKey).flatMap { volumeStates[JSString($0)] }
      let dueByVolume = volumeState == .active || volumeState == .goalMet
      if dueByChapter || dueByMilestone || dueByVolume { return .due }
      return dormant.contains(JSString(ref)) ? .dormant : .open
    }
    let lines = ordered.filter(\.isOpen).map { promise -> (standing: Standing, line: String) in
      let ref = "\(promise.kind.rawValue):\(promise.key)"
      let label = promise.kind == .thread ? (present(promise.text?.jsTrim()) ?? promise.key) : (promise.text ?? "")
      let standing = standing(of: promise, ref: ref)
      // The reference joins a null where a promise never moved, leaving an empty slot between the other facts.
      let facts = [
        "opened ch \(promise.openedChapter.map(String.init) ?? "?")",
        promise.lastAdvancedChapter.map { "last moved ch \($0)" } ?? "",
        "pays off: \(payoffLabel(window: promise.payoffWindow, milestoneKey: promise.payoffMilestoneKey, volumeKey: promise.payoffVolumeKey))",
      ]
      .joined(separator: ", ")
      return (standing, "\(ref) [\(standing.rawValue)] — \(label) (\(facts))")
    }
    let sorted = standingOrder.flatMap { order in lines.filter { $0.standing == order }.map(\.line) }
    return fitLines(sorted, maxTokens: Cap.promises, leftOut: "open promises — get_plot_threads lists them all")
  }
}
