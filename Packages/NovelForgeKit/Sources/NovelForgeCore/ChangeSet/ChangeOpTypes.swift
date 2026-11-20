import ShadowText

struct EndingContract: Sendable, Equatable {
  var hookType: HookType
  var emotionalBeat: String
  var openQuestion: String
  var handoffState: String
  var mustNotResolve: [String]?

  init?(_ record: OrderedJSONObject) {
    let fields = OpFields(record: record)
    guard let hookType: HookType = fields.member("hookType"), let beat = fields.string("emotionalBeat"), let question = fields.string("openQuestion"),
      let handoff = fields.string("handoffState")
    else {
      return nil
    }
    self.hookType = hookType
    emotionalBeat = beat
    openQuestion = question
    handoffState = handoff
    mustNotResolve = fields.strings("mustNotResolve")
  }

  var json: OrderedJSON {
    var encoder = OpEncoder()
    encoder.string("hookType", hookType.rawValue)
    encoder.string("emotionalBeat", emotionalBeat)
    encoder.string("openQuestion", openQuestion)
    encoder.string("handoffState", handoffState)
    encoder.strings("mustNotResolve", mustNotResolve)
    return jsonObject(encoder.pairs.map { ($0.key, $0.value) })
  }
}

struct ChangeKnowledgeContract: Sendable, Equatable {
  var pov: [String]
  var learns: [KnowledgeReveal]?

  init?(_ record: OrderedJSONObject) {
    let fields = OpFields(record: record)
    guard let pov = fields.strings("pov") else { return nil }
    self.pov = pov
    learns = record["learns"]?.arrayValue?.compactMap { entry in
      guard let reveal = entry.objectValue, let entityKey = reveal["entityKey"]?.stringValue, let factKey = reveal["factKey"]?.stringValue else { return nil }
      return KnowledgeReveal(entityKey: entityKey, factKey: factKey)
    }
  }

  var json: OrderedJSON {
    var pairs: [(String, OrderedJSON)] = [("pov", .array(pov.map(OrderedJSON.string)))]
    if let learns { pairs.append(("learns", .array(learns.map { jsonObject([("entityKey", .string($0.entityKey)), ("factKey", .string($0.factKey))]) }))) }
    return jsonObject(pairs)
  }
}

struct PassageRewriteAnchor: Sendable, Equatable {
  var draftId: String
  var revision: Int
  var saveSeq: Int
  var start: Int
  var end: Int
  var passageHash: String
  var paragraph: Int
  var contextBefore: String
  var contextAfter: String

  init?(_ record: OrderedJSONObject) {
    let fields = OpFields(record: record)
    guard let draftId = fields.string("draftId"), let revision = fields.int("revision"), let saveSeq = fields.int("saveSeq"), let start = fields.int("start"),
      let end = fields.int("end"),
      let hash = fields.string("passageHash"), let paragraph = fields.int("paragraph"), let before = fields.string("contextBefore"), let after = fields.string("contextAfter")
    else { return nil }
    self.draftId = draftId
    self.revision = revision
    self.saveSeq = saveSeq
    self.start = start
    self.end = end
    passageHash = hash
    self.paragraph = paragraph
    contextBefore = before
    contextAfter = after
  }

  var json: OrderedJSON {
    jsonObject([
      ("draftId", .string(draftId)), ("revision", .int(Int64(revision))), ("saveSeq", .int(Int64(saveSeq))), ("start", .int(Int64(start))), ("end", .int(Int64(end))),
      ("passageHash", .string(passageHash)), ("paragraph", .int(Int64(paragraph))), ("contextBefore", .string(contextBefore)), ("contextAfter", .string(contextAfter)),
    ])
  }
}

struct OpMetadata: Sendable, Equatable {
  var rationale: String?
  var quote: String?
  var startedEmpty: Bool?
  var ideaId: String?

  init(_ fields: OpFields) {
    rationale = fields.string("rationale")
    quote = fields.string("quote")
    startedEmpty = fields.bool("startedEmpty")
    ideaId = fields.string("ideaId")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("rationale", rationale)
    encoder.string("quote", quote)
    encoder.string("ideaId", ideaId)
    encoder.bool("startedEmpty", startedEmpty)
  }
}

func sceneJSON(_ scene: BriefScene) -> OrderedJSON {
  var pairs: [(String, OrderedJSON)] = [("summary", .string(scene.summary)), ("pov", scene.pov.map(OrderedJSON.string) ?? .null)]
  if let goal = scene.goal { pairs.append(("goal", .string(goal))) }
  if let obstacle = scene.obstacle { pairs.append(("obstacle", .string(obstacle))) }
  if let turn = scene.turn { pairs.append(("turn", .string(turn))) }
  if let beats = scene.beats { pairs.append(("beats", .array(beats.map(OrderedJSON.string)))) }
  if let words = scene.estimatedWords { pairs.append(("estimatedWords", .int(Int64(words)))) }
  return jsonObject(pairs)
}

func unlockJSON(_ condition: UnlockCondition) -> OrderedJSON {
  let terms = condition.all.map { term -> OrderedJSON in
    switch term {
    case .milestone(let key): jsonObject([("milestone", .string(key))])
    case .volume(let key): jsonObject([("volume", .string(key))])
    case .chapter(let number): jsonObject([("chapter", .int(Int64(number)))])
    case .ending: jsonObject([("ending", .bool(true))])
    }
  }
  return jsonObject([("all", .array(terms))])
}
