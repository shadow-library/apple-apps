let withheldMarker = "[withheld]"

private let markerUnits = Array(withheldMarker.utf16)
// Two spans this close can change each other's lookarounds (one code point, two units when astral); farther apart they cannot.
private let interactionGap = 2
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

struct WithholdingOutcome: Equatable, Sendable {
  let text: String
  /// The matches the reference's own order replaced, which is what it counts.
  let count: Int
  /// Per code unit of the input: withheld under at least one order of the ties.
  let hidden: [Bool]
  /// Components whose orders were too many to search, withheld whole.
  let exhaustedComponents: Int
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
private func runOutcomes(_ run: [Int], _ withholdings: [Withholding], from start: ScrubUnits, budget: inout Int) -> Set<ScrubUnits>? {
  if run.count == 1, let index = run.first { return [start.replacing(withholdings[index].pattern)?.scrubbed ?? start] }
  var outcomes = Set<ScrubUnits>()
  var seen = Set<SearchNode>()
  var stack = [SearchNode(state: start, remaining: run, idle: [])]
  while let node = stack.popLast() {
    guard seen.insert(node).inserted else { continue }
    budget -= 1
    guard budget >= 0 else { return nil }
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

/// Withholdings that can affect one another, with the stretch of text their matches can reach (nil: anywhere).
private struct Component {
  var members: [Int]
  var spans: [Range<Int>]?
}

/// A pattern matches only where its lookaround-free body matches the input, and only a body with a bracket next to marker text can reach across a marker, so two
/// withholdings whose bodies never come within `interactionGap` of each other neither enable, disable nor shift each other's matches in any order.
private func components(_ withholdings: [Withholding], in units: [UInt16]) -> [Component] {
  var parent = Array(withholdings.indices)
  func root(_ index: Int) -> Int {
    var index = index
    while parent[index] != index { (parent[index], index) = (parent[parent[index]], parent[index]) }
    return index
  }
  func join(_ left: Int, _ right: Int) { parent[root(left)] = root(right) }

  var spans: [(range: Range<Int>, member: Int)] = []
  var unbounded: [Int] = []
  for (index, withholding) in withholdings.enumerated() {
    guard let reach = withholding.reach else {
      unbounded.append(index)
      continue
    }
    spans += bodyMatches(reach, in: units).map { ($0, index) }
  }
  spans.sort { $0.range.lowerBound < $1.range.lowerBound }
  var cluster: (member: Int, end: Int)? = nil
  for span in spans {
    if let current = cluster, span.range.lowerBound < current.end + interactionGap {
      join(span.member, current.member)
      cluster = (current.member, max(current.end, span.range.upperBound))
    } else {
      cluster = (span.member, span.range.upperBound)
    }
  }
  let reaching = Set(spans.map(\.member))
  if let anchor = unbounded.first {
    for member in unbounded.dropFirst() { join(member, anchor) }
    for member in reaching { join(member, anchor) }
  }

  var byRoot: [Int: Component] = [:]
  var order: [Int] = []
  for index in withholdings.indices where reaching.contains(index) || unbounded.contains(index) {
    let key = root(index)
    if byRoot[key] == nil {
      order.append(key)
      byRoot[key] = Component(members: [], spans: [])
    }
    byRoot[key]?.members.append(index)
  }
  for span in spans { byRoot[root(span.member)]?.spans?.append(span.range) }
  if let anchor = unbounded.first { byRoot[root(anchor)]?.spans = nil }
  return order.compactMap { byRoot[$0] }
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
  var lower = max(0, (spans.map(\.lowerBound).min() ?? 0) - interactionGap)
  var upper = min(units.count, (spans.map(\.upperBound).max() ?? units.count) + interactionGap)
  if lower > 0, UTF16.isTrailSurrogate(units[lower]) { lower -= 1 }
  if upper < units.count, UTF16.isTrailSurrogate(units[upper]) { upper += 1 }
  return lower..<upper
}

/// What one component withholds under any order of its tied members, or nil when every order leaves the same text.
private func componentHidden(_ component: Component, _ withholdings: [Withholding], in units: [UInt16], budget: Int) -> (hidden: [Int], exhausted: Bool)? {
  let members = component.members.map { withholdings[$0] }
  let runs = tieRuns(members)
  guard runs.contains(where: { $0.count > 1 }) else { return nil }
  let range = component.spans.map { window($0, in: units) } ?? units.indices
  let start = ScrubUnits(units: Array(units[range]), origins: range.map { Int32($0) })
  var remaining = budget
  var frontier: Set<ScrubUnits> = [start]
  for run in runs {
    var next = Set<ScrubUnits>()
    for state in frontier {
      guard let outcomes = runOutcomes(run, members, from: state, budget: &remaining) else {
        return (component.spans.map { $0.flatMap { Array($0) } } ?? Array(units.indices), true)
      }
      next.formUnion(outcomes)
    }
    frontier = next
  }
  guard frontier.count > 1 else { return nil }
  var hidden = Set<Int>()
  for outcome in frontier {
    let kept = Set(outcome.origins.lazy.filter { $0 >= 0 }.map { Int($0) })
    for offset in range where !kept.contains(offset) { hidden.insert(offset) }
  }
  return (Array(hidden), false)
}

/// The withholdings applied to `text` in the reference's order, unless another order of tied withholdings would withhold a code unit this one shows: then every code
/// unit any order withholds is withheld, each stretch under one marker. Orders are searched only within components of withholdings that can affect one another; a
/// component with more orders than `budget` allows is withheld over every stretch its matches could reach.
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
    return WithholdingOutcome(text: canonical.text, count: count, hidden: hidden, exhaustedComponents: 0)
  }

  var widened = Array(repeating: false, count: start.units.count)
  var exhausted = 0
  for component in components(withholdings, in: start.units) {
    guard let found = componentHidden(component, withholdings, in: start.units, budget: budget) else { continue }
    for offset in found.hidden { widened[offset] = true }
    if found.exhausted { exhausted += 1 }
  }
  guard widened.contains(true) else { return WithholdingOutcome(text: canonical.text, count: count, hidden: hidden, exhaustedComponents: exhausted) }
  for (offset, isWidened) in widened.enumerated() where isWidened { hidden[offset] = true }
  return WithholdingOutcome(text: marked(canonical, widened: widened), count: count, hidden: hidden, exhaustedComponents: exhausted)
}

/// The reference-order text with each stretch a widened component withholds under one marker; a reference marker over widened units joins that stretch.
private func marked(_ canonical: ScrubUnits, widened: [Bool]) -> String {
  var result: [UInt16] = []
  var inWidened = false
  var index = 0
  while index < canonical.units.count {
    guard canonical.origins[index] < 0 else {
      let isWidened = widened[Int(canonical.origins[index])]
      if !isWidened { result.append(canonical.units[index]) } else if !inWidened { result += markerUnits }
      inWidened = isWidened
      index += 1
      continue
    }
    let previous = canonical.origins[..<index].last { $0 >= 0 }.map { Int($0) + 1 } ?? 0
    let markerEnd = canonical.origins[index...].firstIndex { $0 >= 0 } ?? canonical.units.count
    let next = markerEnd < canonical.units.count ? Int(canonical.origins[markerEnd]) : widened.count
    let isWidened = (previous..<next).contains { widened[$0] }
    if !isWidened { result += canonical.units[index..<markerEnd] } else if !inWidened { result += markerUnits }
    inWidened = isWidened
    index = markerEnd
  }
  return JSText.string(fromCodeUnits: result)
}
