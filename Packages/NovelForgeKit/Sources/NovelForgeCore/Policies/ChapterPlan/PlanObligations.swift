import ShadowText

private let dormantThresholdChapters = 6

enum ObligationKind: String, Sendable {
  case hook
  case promise
  case volumeGoal = "volume_goal"
}

struct PlanObligation: Equatable, Sendable {
  let kind: ObligationKind
  let ref: String?
  let text: String
}

struct PlanPromise: Equatable, Sendable {
  var kind: PromiseKind
  var key: String
  var text: String?
  var isOpen: Bool
  var intentionallyOpen: Bool
  var openedChapter: Int?
  var lastAdvancedChapter: Int?
  var payoff: PromisePayoff
}

struct PlanEnding: Equatable, Sendable {
  var openQuestion: String?
  var handoffState: String?
}

struct ObligationVolume: Equatable, Sendable {
  var volumeKey: String
  var title: String?
  var objective: String?
}

struct ObligationSources: Sendable {
  var chapter: Int
  var previousEnding: PlanEnding?
  var threads: [PlanPromise]
  var mysteries: [PlanPromise]
  var volume: ObligationVolume?
  var milestoneStates: [JSString: MilestoneState] = [:]
  var volumeStates: [JSString: VolumeState] = [:]
}

private enum PromiseFlag {
  case dormant
  case overdue
}

private enum DueBy {
  case chapter
  case milestone
  case volume
}

private struct PromiseCandidate {
  let ref: String
  let label: String
  let quietSince: Int
  let payoffWindow: Int?
  let due: Bool
  let dueBy: DueBy?
  let overdue: Bool
}

private func trimmedText(_ value: String?) -> String? {
  guard let trimmed = value?.jsTrim(), !trimmed.isEmpty else { return nil }
  return trimmed
}

private func promiseRef(_ promise: PlanPromise) -> String { "\(promise.kind.rawValue):\(promise.key)" }

// apps/novel-forge-server/src/modules/ai/context/dormant-threads.ts:28
private func flags(_ promises: [PlanPromise], currentChapter: Int) -> [JSString: PromiseFlag] {
  var flagged: [JSString: PromiseFlag] = [:]
  for promise in promises where promise.isOpen && !promise.intentionallyOpen {
    let overdue = promise.payoff.payoffWindow.map { currentChapter > $0 } ?? false
    let staleness = currentChapter - (promise.lastAdvancedChapter ?? promise.openedChapter ?? 0)
    guard overdue || staleness > dormantThresholdChapters else { continue }
    flagged[JSString(promiseRef(promise))] = overdue ? .overdue : .dormant
  }
  return flagged
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:82
private func hookObligation(_ chapter: Int, _ ending: PlanEnding?) -> PlanObligation? {
  guard chapter > 1, let ending else { return nil }
  let question = trimmedText(ending.openQuestion)
  let handoff = trimmedText(ending.handoffState)
  guard question != nil || handoff != nil else { return nil }
  let opens = handoff.map { "; this chapter opens from: \($0)" } ?? ""
  let subject = question.map { "\"\($0)\"" } ?? "its handoff"
  return PlanObligation(kind: .hook, ref: "chapter:\(chapter - 1)", text: "Chapter \(chapter - 1) ends on \(subject)\(opens)")
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:96
private func byUrgency(_ left: PromiseCandidate, _ right: PromiseCandidate) -> Int {
  func rank(_ candidate: PromiseCandidate) -> Int { candidate.overdue ? 0 : candidate.due ? 1 : 2 }
  let byRank = rank(left) - rank(right)
  if byRank != 0 { return byRank }
  if rank(left) == 0, left.dueBy == .chapter, right.dueBy == .chapter, let leftWindow = left.payoffWindow, let rightWindow = right.payoffWindow, leftWindow != rightWindow {
    return leftWindow - rightWindow
  }
  if left.quietSince != right.quietSince { return left.quietSince - right.quietSince }
  if JSText.codeUnitPrecedes(left.ref, right.ref) { return -1 }
  return JSText.codeUnitPrecedes(right.ref, left.ref) ? 1 : 0
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:108
private func candidate(_ promise: PlanPromise, label: String, sources: ObligationSources) -> PromiseCandidate {
  let chapter = sources.chapter
  let standing = resolvePromiseDueStanding(promise.payoff, chapter: chapter, milestoneStates: sources.milestoneStates, volumeStates: sources.volumeStates)
  let dueByChapter = promise.payoff.payoffWindow.map { $0 <= chapter } ?? false
  let dueByMilestone = promise.payoff.payoffMilestoneKey.map { sources.milestoneStates[JSString($0)] == .reached } ?? false
  let dueBy: DueBy? = dueByChapter ? .chapter : dueByMilestone ? .milestone : standing != .notDue ? .volume : nil
  return PromiseCandidate(
    ref: promiseRef(promise),
    label: label,
    quietSince: promise.lastAdvancedChapter ?? promise.openedChapter ?? 0,
    payoffWindow: promise.payoff.payoffWindow,
    due: standing != .notDue,
    dueBy: dueBy,
    overdue: standing == .overdue
  )
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:138
private func promiseObligation(_ sources: ObligationSources) -> PlanObligation? {
  let flagged = flags(sources.threads + sources.mysteries, currentChapter: sources.chapter - 1)
  let open = { (promise: PlanPromise) in promise.isOpen && !promise.intentionallyOpen }
  let candidates =
    sources.threads.filter(open).map { candidate($0, label: trimmedText($0.text) ?? $0.key, sources: sources) }
    + sources.mysteries.filter(open).map { candidate($0, label: $0.text ?? "", sources: sources) }
  guard let top = jsArraySorted(candidates, compare: byUrgency).first else { return nil }
  let reason = flagged[JSString(top.ref)]
  switch top.dueBy {
  case .chapter:
    let when = reason == .overdue ? "was due by chapter" : "is due by chapter"
    return PlanObligation(kind: .promise, ref: top.ref, text: "A promise that \(when) \(top.payoffWindow.map(String.init) ?? "null"): \(top.label)")
  case .milestone:
    return PlanObligation(kind: .promise, ref: top.ref, text: "A promise due now that its payoff milestone is reached: \(top.label)")
  case .volume:
    let line = top.overdue ? "A promise overdue — its payoff volume already met its goal: \(top.label)" : "A promise due while its payoff volume is active: \(top.label)"
    return PlanObligation(kind: .promise, ref: top.ref, text: line)
  case nil:
    let quiet = top.quietSince > 0 ? "quiet since chapter \(top.quietSince)" : "not moved since it opened"
    let dormant = reason == .dormant ? ", dormant" : ""
    return PlanObligation(kind: .promise, ref: top.ref, text: "The longest-quiet promise (\(quiet)\(dormant)): \(top.label)")
  }
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:163
private func volumeObligation(_ volume: ObligationVolume?) -> PlanObligation? {
  guard let volume, let objective = trimmedText(volume.objective) else { return nil }
  return PlanObligation(kind: .volumeGoal, ref: "volume:\(volume.volumeKey)", text: "The goal of \(trimmedText(volume.title) ?? volume.volumeKey): \(objective)")
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:170
// Feed threads and mysteries in one canonical order (e.g. sorted by key): the urgency comparator is intransitive, so replicas must agree on input order.
func selectObligations(_ sources: ObligationSources) -> [PlanObligation] {
  [hookObligation(sources.chapter, sources.previousEnding), promiseObligation(sources), volumeObligation(sources.volume)].compactMap { $0 }
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:176
func renderObligations(_ obligations: [PlanObligation]) -> String {
  if obligations.isEmpty { return "(none recorded — choose from the catalog)" }
  return obligations.map { "- \($0.text)\($0.ref.map { " [\($0)]" } ?? "")" }.joined(separator: "\n")
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:181
func planRationale(_ obligations: [PlanObligation], moves: String? = nil) -> String? {
  var lines = obligations.map { "- \($0.text)" }
  if let moves = trimmedText(moves) { lines.append("This plan moves: \(moves)") }
  return lines.isEmpty ? nil : "What the story owes now:\n\(lines.joined(separator: "\n"))"
}
