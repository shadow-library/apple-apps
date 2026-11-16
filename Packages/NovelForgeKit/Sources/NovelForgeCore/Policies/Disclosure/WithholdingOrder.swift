let withheldMarker = "[withheld]"

private let markerUnits = Array(withheldMarker.utf16)
// A lookaround reads one code point, two units when astral.
private let lookaroundUnits = 2
let orderSearchBudget = 2_048

/// A text being scrubbed, each code unit with its offset in the text before scrubbing; a marker's units have none (-1).
struct ScrubUnits: Hashable, Sendable {
  var units: [UInt16]
  var origins: [Int32]

  init(_ text: String) {
    units = text.jsCodeUnits
    origins = units.indices.map { Int32($0) }
  }

  init(units: [UInt16], origins: [Int32]) {
    self.units = units
    self.origins = origins
  }

  /// `text.replace(pattern, () => '[withheld]')` for a global pattern; nil when it matches nothing.
  func replacing(_ pattern: JSRegex) -> (scrubbed: ScrubUnits, count: Int)? {
    let matches = pattern.allMatchSlots(in: units)
    if matches.isEmpty { return nil }
    var next = ScrubUnits(units: [], origins: [])
    var cursor = 0
    for slots in matches {
      next.units += units[cursor..<slots[0]] + markerUnits
      next.origins += origins[cursor..<slots[0]] + Array(repeating: -1, count: markerUnits.count)
      cursor = slots[1]
    }
    next.units += units[cursor...]
    next.origins += origins[cursor...]
    return (next, matches.count)
  }

  var text: String { JSText.string(fromCodeUnits: units) }
}

/// The work an order search did, counted rather than timed.
struct OrderSearchCost: Equatable, Sendable {
  var states = 0
  /// Code units the patterns tried at each state ran over.
  var scannedUnits = 0
  var largestWindow = 0
}

struct WithholdingOutcome: Equatable, Sendable {
  let text: String
  /// The matches the reference's own order replaced, which is what it counts.
  let count: Int
  /// Per code unit of the input: withheld under at least one order of the ties.
  let hidden: [Bool]
  /// Components whose orders were too many to search, withheld over every stretch they could reach.
  let exhaustedComponents: Int
  /// One of them was the whole text, a withholding of unknown reach having joined every other.
  let exhaustedWholeText: Bool
  let searchCost: OrderSearchCost
}

/// Withholdings that could change places with one another in the reference: equal weights, whose order follows the database's unordered or collated reads, and a
/// de-duplicated pattern whose kept weight depends on that order. Each run is a maximal stretch whose possible weights overlap.
func tieRuns(_ withholdings: [Withholding]) -> [[Int]] {
  var runs: [(members: [Int], lowest: Int)] = []
  for (index, withholding) in withholdings.enumerated() {
    let first = runs.firstIndex { withholding.possibleWeights.upperBound >= $0.lowest } ?? runs.count
    let merged = runs[first...]
    let lowest = min(merged.map(\.lowest).min() ?? Int.max, withholding.possibleWeights.lowerBound)
    let members = merged.flatMap(\.members) + [index]
    runs.removeSubrange(first...)
    runs.append((members, lowest))
  }
  return runs.map(\.members)
}

private struct SearchNode: Hashable {
  let state: ScrubUnits
  let remaining: [Int]
  /// Patterns that matched nothing at some point on this path, so an order may have spent them there.
  let idle: [Int]
}

/// Every text one run can leave, over every order of its members. A path applies patterns that match; it may end once each unapplied member has matched nothing at
/// some point along it, since an order can place that member there.
private func runOutcomes(_ run: [Int], _ withholdings: [Withholding], from start: ScrubUnits, budget: inout Int, cost: inout OrderSearchCost) -> Set<ScrubUnits>? {
  if run.count == 1, let index = run.first {
    cost.scannedUnits += start.units.count
    return [start.replacing(withholdings[index].pattern)?.scrubbed ?? start]
  }
  var outcomes = Set<ScrubUnits>()
  var seen = Set<SearchNode>()
  var stack = [SearchNode(state: start, remaining: run, idle: [])]
  while let node = stack.popLast() {
    guard seen.insert(node).inserted else { continue }
    budget -= 1
    guard budget >= 0 else { return nil }
    cost.states += 1
    cost.scannedUnits += node.remaining.count * node.state.units.count
    var idle = Set(node.idle)
    var applied: [(index: Int, state: ScrubUnits)] = []
    for index in node.remaining {
      if let next = node.state.replacing(withholdings[index].pattern) { applied.append((index, next.scrubbed)) } else { idle.insert(index) }
    }
    if node.remaining.allSatisfy(idle.contains) { outcomes.insert(node.state) }
    for (index, state) in applied {
      let remaining = node.remaining.filter { $0 != index }
      stack.append(SearchNode(state: state, remaining: remaining, idle: remaining.filter(idle.contains)))
    }
  }
  return outcomes
}

/// Withholdings whose matches can affect one another's, with the stretches of text those matches can reach (nil: anywhere).
private struct Component {
  var members: [Int]
  var spans: [Range<Int>]?
}

/// A withholding matches only within its reach (see `WithholdingReach`) and reads one code point on either side through its lookarounds; a code point between two
/// reaches is in none, so nothing rewrites it, and withholdings whose reaches neither overlap nor touch never enable, disable or shift each other's matches. A body
/// that takes marker text reaches through what others can hide, its own sites included, so its sites grow to a fixpoint. A withholding that rewrites marker letters
/// only matters beside one that takes marker text. Components are stretches of text, not sets of withholdings: a withholding that reaches two apart has independent
/// matches in each, and what any order withholds is the union of what it withholds in each.
private func components(_ withholdings: [Withholding], in units: [UInt16]) -> [Component] {
  var spans: [(range: Range<Int>, member: Int)] = []
  var takingMarkers: [(member: Int, pieceMatches: [[Range<Int>]])] = []
  var rewriters: [Int] = []
  for (index, withholding) in withholdings.enumerated() {
    switch withholding.reach {
    case nil:
      return [Component(members: Array(withholdings.indices), spans: nil)]
    case .body(let body, let rewritesMarkers):
      spans += bodyMatches(body, in: units).map { ($0, index) }
      if rewritesMarkers { rewriters.append(index) }
    case .markers(let pieces):
      takingMarkers.append((index, pieces.map { bodyMatches($0, in: units) }))
    }
  }
  if !takingMarkers.isEmpty {
    var hideable = Array(repeating: false, count: units.count)
    for span in spans {
      for offset in span.range where offset < units.count { hideable[offset] = true }
    }
    var sites: [[Range<Int>]]
    while true {
      sites = takingMarkers.map { markerSites($0.pieceMatches, in: units, hideable: hideable) }
      var grown = hideable
      for site in sites.joined() {
        for offset in site { grown[offset] = true }
      }
      if grown == hideable { break }
      hideable = grown
    }
    for (taking, memberSites) in zip(takingMarkers, sites) { spans += memberSites.map { ($0, taking.member) } }
  }

  spans.sort { $0.range.lowerBound < $1.range.lowerBound }
  var stretches: [(members: Set<Int>, spans: [Range<Int>], end: Int)] = []
  for span in spans {
    if let last = stretches.indices.last, span.range.lowerBound <= stretches[last].end {
      stretches[last].members.insert(span.member)
      stretches[last].spans.append(span.range)
      stretches[last].end = max(stretches[last].end, span.range.upperBound)
    } else {
      stretches.append(([span.member], [span.range], span.range.upperBound))
    }
  }
  let marking = Set(takingMarkers.map(\.member))
  return stretches.map { stretch in
    let members = stretch.members.isDisjoint(with: marking) ? stretch.members : stretch.members.union(rewriters)
    return Component(members: members.sorted(), spans: stretch.spans)
  }
}

/// Where the body matches starting at each offset, overlapping ones included.
private func bodyMatches(_ body: JSRegex, in units: [UInt16]) -> [Range<Int>] {
  var matches: [Range<Int>] = []
  var from = 0
  while from <= units.count, let slots = body.firstMatchSlots(in: units, from: from) {
    matches.append(slots[0]..<max(slots[1], slots[0] + 1))
    from = slots[0] + (slots[0] < units.count && UTF16.isLeadSurrogate(units[slots[0]]) ? 2 : 1)
  }
  return matches
}

/// The input stretch a component's search runs over: its spans with room for their lookarounds, on code point boundaries.
private func window(_ spans: [Range<Int>], in units: [UInt16]) -> Range<Int> {
  var lower = max(0, (spans.map(\.lowerBound).min() ?? 0) - lookaroundUnits)
  var upper = min(units.count, (spans.map(\.upperBound).max() ?? units.count) + lookaroundUnits)
  if lower > 0, UTF16.isTrailSurrogate(units[lower]) { lower -= 1 }
  if upper < units.count, UTF16.isTrailSurrogate(units[upper]) { upper += 1 }
  return lower..<upper
}

private enum ComponentResult {
  case agrees
  case widened([Int])
  case exhausted([Int])
}

/// What one component withholds under any order of its tied members; orders that withhold the same code units agree, whatever marker text they leave.
private func componentHidden(_ component: Component, _ withholdings: [Withholding], in units: [UInt16], budget: Int, cost: inout OrderSearchCost) -> ComponentResult {
  let members = component.members.map { withholdings[$0] }
  let runs = tieRuns(members)
  guard runs.contains(where: { $0.count > 1 }) else { return .agrees }
  let range = component.spans.map { window($0, in: units) } ?? units.indices
  cost.largestWindow = max(cost.largestWindow, range.count)
  let start = ScrubUnits(units: Array(units[range]), origins: range.map { Int32($0) })
  var remaining = budget
  var frontier: Set<ScrubUnits> = [start]
  for run in runs {
    var next = Set<ScrubUnits>()
    for state in frontier {
      guard let outcomes = runOutcomes(run, members, from: state, budget: &remaining, cost: &cost) else {
        return .exhausted(component.spans.map { $0.flatMap { Array($0) } } ?? Array(units.indices))
      }
      next.formUnion(outcomes)
    }
    frontier = next
  }
  let hiddenSets = Set(
    frontier.map { outcome in
      let kept = Set(outcome.origins.lazy.filter { $0 >= 0 }.map { Int($0) })
      return Set(range.filter { !kept.contains($0) })
    })
  guard hiddenSets.count > 1 else { return .agrees }
  return .widened(Array(hiddenSets.reduce(into: Set<Int>()) { $0.formUnion($1) }))
}

/// The withholdings applied to `text` in the reference's order, unless orders of tied withholdings withhold different code units: then every code unit any order
/// withholds is withheld, each withheld stretch of the whole text under one marker. Orders that differ only in the marker text they leave keep the reference order's
/// text, one of their outputs. Orders are searched only within components of withholdings that can affect one another; a component with more orders than `budget`
/// allows is withheld over every stretch its matches could reach.
func applyWithholdings(_ withholdings: [Withholding], to text: String, budget: Int = orderSearchBudget) -> WithholdingOutcome {
  let start = ScrubUnits(text)
  var canonical = start
  var count = 0
  for withholding in withholdings {
    guard let next = canonical.replacing(withholding.pattern) else { continue }
    canonical = next.scrubbed
    count += next.count
  }
  var hidden = Array(repeating: true, count: start.units.count)
  for origin in canonical.origins where origin >= 0 { hidden[Int(origin)] = false }
  guard tieRuns(withholdings).contains(where: { $0.count > 1 }) else {
    return WithholdingOutcome(text: canonical.text, count: count, hidden: hidden, exhaustedComponents: 0, exhaustedWholeText: false, searchCost: OrderSearchCost())
  }

  var widened = Array(repeating: false, count: start.units.count)
  var exhausted = 0
  var exhaustedWholeText = false
  var cost = OrderSearchCost()
  for component in components(withholdings, in: start.units) {
    switch componentHidden(component, withholdings, in: start.units, budget: budget, cost: &cost) {
    case .agrees:
      continue
    case .widened(let offsets):
      for offset in offsets { widened[offset] = true }
    case .exhausted(let offsets):
      for offset in offsets { widened[offset] = true }
      exhausted += 1
      if component.spans == nil { exhaustedWholeText = true }
    }
  }
  guard widened.contains(true) else {
    return WithholdingOutcome(text: canonical.text, count: count, hidden: hidden, exhaustedComponents: exhausted, exhaustedWholeText: exhaustedWholeText, searchCost: cost)
  }
  for (offset, isWidened) in widened.enumerated() where isWidened { hidden[offset] = true }
  let text = marked(start.units, hidden: hidden)
  return WithholdingOutcome(text: text, count: count, hidden: hidden, exhaustedComponents: exhausted, exhaustedWholeText: exhaustedWholeText, searchCost: cost)
}

/// The text with each withheld stretch under one marker.
private func marked(_ units: [UInt16], hidden: [Bool]) -> String {
  var result: [UInt16] = []
  for (offset, unit) in units.enumerated() {
    if !hidden[offset] {
      result.append(unit)
    } else if offset == 0 || !hidden[offset - 1] {
      result += markerUnits
    }
  }
  return JSText.string(fromCodeUnits: result)
}
