import ShadowText

// apps/novel-forge-server/src/database/schemas/ledger.ts:33
enum RejectionAnchor: Sendable, Equatable {
  case volume(String?)
  case states([(ref: String, state: ArtifactState)])

  static func == (left: RejectionAnchor, right: RejectionAnchor) -> Bool {
    switch (left, right) {
    case (.volume(let a), .volume(let b)): sameText(a, b)
    case (.states(let a), .states(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.ref.jsEquals($1.ref) && $0.state == $1.state }
    default: false
    }
  }

  var json: OrderedJSON {
    switch self {
    case .volume(let key): jsonObject([("volumeKey", key.map(OrderedJSON.string) ?? .null)])
    case .states(let states): jsonObject([("states", .object(OrderedJSONObject(states.map { (key: $0.ref, value: $0.state.json) })))])
    }
  }

  init?(json: OrderedJSON) {
    guard case .object(let record) = json else { return nil }
    switch (record["volumeKey"], record["states"]) {
    case (let key?, nil):
      guard key.isNull || key.stringValue != nil else { return nil }
      self = .volume(key.stringValue)
    case (nil, .object(let states)?):
      let parsed = states.entries.compactMap { entry in ArtifactState(json: entry.value).map { (ref: entry.key, state: $0) } }
      guard parsed.count == states.entries.count else { return nil }
      self = .states(parsed)
    default:
      return nil
    }
  }

  fileprivate var anchoredStates: [(ref: String, state: ArtifactState)]? {
    guard case .states(let states) = self else { return nil }
    return states
  }
}

// apps/novel-forge-server/src/modules/refinement/idea-rejections.ts:8
struct IdeaRejectionEntry: Sendable, Equatable {
  let ideaId: String?
  let rejectionScope: LedgerRejectionScope?
  let rejectionAnchor: RejectionAnchor?
  var superseded = false
}

// apps/novel-forge-server/src/modules/refinement/idea-rejections.ts:10
struct RejectionContext: Sendable {
  let activeVolumeKey: String?
  let states: [JSString: ArtifactState]

  init(activeVolumeKey: String?, states: [JSString: ArtifactState] = [:]) {
    self.activeVolumeKey = activeVolumeKey
    self.states = states
  }
}

struct RejectionVolume: Sendable, Equatable {
  let volumeKey: String
  let ordinal: Int
  let state: VolumeState
}

// apps/novel-forge-server/src/modules/refinement/idea-rejections.ts:22
private func sameState(_ recorded: ArtifactState, _ current: ArtifactState?) -> Bool {
  recorded == (current ?? .missing)
}

// apps/novel-forge-server/src/modules/refinement/idea-rejections.ts:27
func rejectionInScope(_ entry: IdeaRejectionEntry, _ context: RejectionContext) -> Bool {
  guard entry.ideaId != nil, !entry.superseded, let scope = entry.rejectionScope else { return false }
  switch scope {
  case .never:
    return true
  case .notNow:
    guard case .volume(let key)? = entry.rejectionAnchor else { return false }
    return sameText(key, context.activeVolumeKey)
  case .notThisVersion:
    guard let states = entry.rejectionAnchor?.anchoredStates, !states.isEmpty else { return false }
    return states.allSatisfy { sameState($0.state, context.states[JSString($0.ref)]) }
  }
}

// apps/novel-forge-server/src/modules/refinement/idea-rejections.ts:42
func rejectionAnchor(_ scope: LedgerRejectionScope, _ context: RejectionContext, refs: [String]) -> RejectionAnchor? {
  switch scope {
  case .never: nil
  case .notNow: .volume(context.activeVolumeKey)
  case .notThisVersion: .states(refs.jsUnique().map { (ref: $0, state: context.states[JSString($0)] ?? .missing) })
  }
}

// replaces loadActiveVolumeKey (idea-rejections.ts:48)
func activeVolumeKey(in volumes: [RejectionVolume]) -> String? {
  var first: RejectionVolume?
  for volume in volumes where volume.state == .active {
    guard let current = first else {
      first = volume
      continue
    }
    if volume.ordinal < current.ordinal { first = volume }
  }
  return first?.volumeKey
}

// replaces the ref gathering in loadRejectionContext (idea-rejections.ts:56)
func rejectionStateRefs(for entries: [IdeaRejectionEntry], refs: [String] = []) -> [String] {
  let anchored = entries.flatMap { entry in
    entry.rejectionScope == .notThisVersion && !entry.superseded ? (entry.rejectionAnchor?.anchoredStates ?? []).map(\.ref) : []
  }
  return (anchored + refs).jsUnique()
}

// replaces loadRejectionContext (idea-rejections.ts:56) and loadArtifactStates (artifact-state.ts)
func rejectionContext(for entries: [IdeaRejectionEntry], refs: [String] = [], volumes: [RejectionVolume], artifactStates: [JSString: ArtifactState]) -> RejectionContext {
  let states = rejectionStateRefs(for: entries, refs: refs).map { (ref: JSString($0), state: artifactStates[JSString($0)] ?? .missing) }
  return RejectionContext(activeVolumeKey: activeVolumeKey(in: volumes), states: Dictionary(states.map { ($0.ref, $0.state) }) { first, _ in first })
}

// replaces loadRejectedIdeas (idea-rejections.ts:67)
func activeRejectedIdeas(_ ideaIds: [String], entries: [IdeaRejectionEntry], volumes: [RejectionVolume], artifactStates: [JSString: ArtifactState]) -> Set<JSString> {
  if ideaIds.isEmpty { return [] }
  let wanted = Set(ideaIds.map { JSString($0) })
  let matching = entries.filter { entry in entry.ideaId.map { wanted.contains(JSString($0)) } ?? false }
  if matching.isEmpty { return [] }
  let context = rejectionContext(for: matching, volumes: volumes, artifactStates: artifactStates)
  return Set(matching.compactMap { entry in entry.ideaId.flatMap { rejectionInScope(entry, context) ? JSString($0) : nil } })
}

// replaces withoutLapsedRejections (idea-rejections.ts:76)
func withoutLapsedRejections<Entry>(
  _ entries: [Entry], rejection: (Entry) -> IdeaRejectionEntry, volumes: [RejectionVolume], artifactStates: [JSString: ArtifactState]
) -> [Entry] {
  func isRejection(_ entry: IdeaRejectionEntry) -> Bool { !(entry.ideaId ?? "").isEmpty && entry.rejectionScope != nil }
  let rejections = entries.map(rejection).filter(isRejection)
  if rejections.isEmpty { return entries }
  let context = rejectionContext(for: rejections, volumes: volumes, artifactStates: artifactStates)
  return entries.filter { entry in
    let item = rejection(entry)
    return !isRejection(item) || rejectionInScope(item, context)
  }
}
