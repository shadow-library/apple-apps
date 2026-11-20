import ShadowText

private typealias WireSchema = OrderedJSON

private func wire(_ pairs: [(String, OrderedJSON)]) -> WireSchema { jsonObject(pairs) }

private func wireType(_ type: String) -> WireSchema { wire([("type", .string(type))]) }

private func wireEnum<Value: RawRepresentable & CaseIterable>(_: Value.Type) -> WireSchema where Value.RawValue == String {
  wire([("type", .string("string")), ("enum", .array(Value.allCases.map { .string($0.rawValue) }))])
}

private func wireList(_ items: WireSchema, extra: [(String, OrderedJSON)] = []) -> WireSchema { wire([("type", .string("array")), ("items", items)] + extra) }

private func wireObject(_ properties: [(String, WireSchema)], required: [String]) -> WireSchema {
  wire([("type", .string("object")), ("properties", wire(properties)), ("required", .array(required.map(OrderedJSON.string))), ("additionalProperties", .bool(false))])
}

private let nonBlank = wire([("type", .string("string")), ("minLength", .int(1))])
private let nonBlankList = wireList(nonBlank)
private let spacelessKey = wire([("type", .string("string")), ("pattern", .string("^[A-Za-z0-9_.:-]+$"))])
private let biblePageSection = wireEnum(BiblePageSection.self)
private let promiseReference: [(String, WireSchema)] = [("kind", wireEnum(PromiseKind.self)), ("key", spacelessKey)]
private let integerFrom1 = wire([("type", .string("integer")), ("minimum", .int(1))])

private func wireKind(_ kind: OpFieldKind) -> WireSchema {
  switch kind {
  case .string, .nullableString: wireType("string")
  case .integer, .nullableInteger: wireType("integer")
  case .boolean: wireType("boolean")
  case .strings, .nullableStrings: wireList(wireType("string"))
  case .object, .nullableObject: wireType("object")
  case .objects, .nullableObjects: wireList(wireType("object"))
  }
}

private enum WireField {
  case typed(WireSchema)
  case offTheWire
}

private func wireFields(_ op: OpType) -> [(String, WireField)] {
  switch op {
  case .bibleDocumentUpsert, .bibleDocumentRemove:
    return [("section", .typed(biblePageSection))]
  case .volumeUpsert:
    return [("state", .offTheWire)]
  case .briefUpdate:
    let endingContract = wireObject(
      [
        ("hookType", wireEnum(HookType.self)), ("emotionalBeat", nonBlank), ("openQuestion", nonBlank), ("handoffState", nonBlank),
        ("mustNotResolve", wireList(wireType("string"))),
      ],
      required: ["hookType", "emotionalBeat", "openQuestion", "handoffState"]
    )
    let knowledgeContract = wireObject(
      [
        ("pov", wireList(nonBlank, extra: [("minItems", .int(1))])),
        ("learns", wireList(wireObject([("entityKey", nonBlank), ("factKey", nonBlank)], required: ["entityKey", "factKey"]))),
      ],
      required: ["pov"]
    )
    return [
      ("writeMode", .typed(wireEnum(BriefWriteMode.self))), ("contentMode", .typed(wireEnum(ContentMode.self))), ("endingContract", .typed(endingContract)),
      ("knowledgeContract", .typed(knowledgeContract)),
      ("scenes", .typed(wireList(wireObject([("summary", nonBlank), ("pov", nonBlank)], required: ["summary"])))), ("claimedMilestones", .typed(nonBlankList)),
    ]
  case .entityUpsert:
    return [("type", .typed(wireEnum(EntityType.self)))]
  case .factUpsert:
    return [("revealChapter", .typed(integerFrom1)), ("unlock", .offTheWire), ("allowedClues", .typed(nonBlankList))]
  case .milestoneUpsert:
    return [("milestoneKey", .typed(spacelessKey)), ("label", .typed(nonBlank)), ("kind", .typed(wireEnum(MilestoneKind.self)))]
  case .milestoneRemove:
    return [("milestoneKey", .typed(spacelessKey))]
  case .promiseCreate:
    return promiseReference.map { ($0.0, .typed($0.1)) } + [("label", .typed(nonBlank))]
  case .promiseUpdate:
    return promiseReference.map { ($0.0, .typed($0.1)) } + [("status", .typed(wireEnum(PromiseOpStatus.self)))]
  case .promiseSetPayoff, .promiseDrop:
    return promiseReference.map { ($0.0, .typed($0.1)) }
  case .draftRewritePassage:
    return [("passage", .typed(nonBlank)), ("contextIndex", .typed(integerFrom1))]
  case .actionGenerateChapter:
    return [("chapter", .typed(integerFrom1))]
  case .actionValidate:
    return [("scope", .typed(wireEnum(ValidationScope.self)))]
  default:
    return []
  }
}

private func opWireSchema(_ op: OpType, _ options: OpVocabularyOptions) -> WireSchema {
  let spec = op.spec
  let hidden = modelHiddenFields(op, options)
  let overrides = wireFields(op)
  var properties: [(String, WireSchema)] = [("op", wire([("type", .string("string")), ("enum", .array([.string(op.rawValue)]))]))]
  for field in spec.required + spec.optional where !hidden.contains(where: { $0.jsEquals(field.name) }) {
    switch overrides.first(where: { $0.0.jsEquals(field.name) })?.1 {
    case .offTheWire?: continue
    case .typed(let schema)?: properties.append((field.name, schema))
    case nil: properties.append((field.name, wireKind(field.kind)))
    }
  }
  return wireObject(properties, required: ["op"] + spec.required.map(\.name))
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-wire-schema.ts:95
struct ChangeSetItemSchema: Sendable, Equatable {
  let ops: [OpType]
  let options: OpVocabularyOptions

  init(_ ops: [OpType], options: OpVocabularyOptions = OpVocabularyOptions()) {
    self.ops = ops
    self.options = options
  }

  var json: OrderedJSON { jsonObject([("anyOf", .array(ops.map { opWireSchema($0, options) }))]) }

  var text: String { json.jsonText }
}

// apps/novel-forge-server/src/modules/notes/organise-plan.ts:63
let organiseChangeOps: [OpType] = [.bibleDocumentUpsert, .bibleDocumentRemove, .entityUpsert, .entityRemove, .organiseRule]
