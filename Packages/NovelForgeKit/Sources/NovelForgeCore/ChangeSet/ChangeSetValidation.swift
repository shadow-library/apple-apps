struct ChangeSetValidationOptions: Sendable {
  var entityMaterialization: Bool

  init(entityMaterialization: Bool = true) {
    self.entityMaterialization = entityMaterialization
  }
}

struct ChangeSetValidation: Sendable {
  let errors: [String]
  let value: OrderedJSON
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-validation.ts:220
let pluginAllowedOps: [OpType] = [.entityUpsert, .entityRemove, .factUpsert, .factRemove, .bibleDocumentUpsert, .bibleDocumentRemove, .briefUpdate]

private let briefStructureFields = ["volumeKey", "contentMode", "claimedMilestones", "isEnding"]
private let anchorCounts = ["revision", "saveSeq", "start", "end", "paragraph"]
private let anchorTexts = ["draftId", "passageHash", "contextBefore", "contextAfter"]
private let objectPrototypeNames = [
  "constructor", "__defineGetter__", "__defineSetter__", "hasOwnProperty", "__lookupGetter__", "__lookupSetter__", "isPrototypeOf", "propertyIsEnumerable", "toString", "valueOf",
  "__proto__",
  "toLocaleString",
]

private func joined<Value: RawRepresentable & CaseIterable>(_: Value.Type, separator: String = ", ") -> String where Value.RawValue == String {
  Value.allCases.map(\.rawValue).joined(separator: separator)
}

extension RawRepresentable where Self: CaseIterable, RawValue == String {
  init?(exactly value: OrderedJSON?) {
    guard case .string(let text)? = value, let match = Self.allCases.first(where: { $0.rawValue.jsEquals(text) }) else { return nil }
    self = match
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-validation.ts:22
private func matches(_ value: OrderedJSON?, _ kind: OpFieldKind) -> Bool {
  guard let value else { return false }
  if case .null = value, kind.admitsNull { return true }
  switch kind {
  case .string, .nullableString: return value.stringValue != nil
  case .boolean:
    if case .bool = value { return true }
    return false
  case .integer, .nullableInteger: return value.isJSInteger
  case .strings, .nullableStrings: return value.arrayValue?.allSatisfy { $0.stringValue != nil } ?? false
  case .objects, .nullableObjects: return value.arrayValue?.allSatisfy { $0.objectValue != nil } ?? false
  case .object, .nullableObject: return value.objectValue != nil
  }
}

extension OrderedJSON {
  var isJSInteger: Bool {
    switch self {
    case .int: true
    case .double(let number): number.jsIsInteger
    default: false
    }
  }

  var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  var jsStringValue: String {
    switch self {
    case .null: ""
    case .bool(let flag): flag ? "true" : "false"
    case .int(let number): Double(number).jsString
    case .double(let number): number.jsString
    case .string(let text): text
    case .array(let items): items.map { $0.jsStringValue }.joined(separator: ",")
    case .object: "[object Object]"
    }
  }
}

private func describe(_ value: OrderedJSON?) -> String {
  guard let value else { return "undefined" }
  if value.isNull { return "null" }
  return value.jsStringValue
}

private func isNonEmptyString(_ value: OrderedJSON?) -> Bool {
  guard case .string(let text)? = value else { return false }
  return !text.isEmpty
}

private func isKeyWithoutSpaces(_ text: String) -> Bool {
  !text.isEmpty && !text.unicodeScalars.contains(where: JSText.isWhitespace)
}

private func isBlankOrNotString(_ value: OrderedJSON) -> Bool {
  guard case .string(let text) = value else { return true }
  return text.jsTrim().isEmpty
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-validation.ts:33
private func endingContractErrors(_ value: OrderedJSON?, path: String) -> [String] {
  guard let contract = value?.objectValue else { return ["\(path): endingContract must be an object"] }
  var errors: [String] = []
  if HookType(exactly: contract["hookType"]) == nil { errors.append("\(path): endingContract.hookType must be one of \(joined(HookType.self))") }
  for key in ["emotionalBeat", "openQuestion", "handoffState"] where !isNonEmptyString(contract[key]) {
    errors.append("\(path): endingContract.\(key) must be a non-empty string")
  }
  if let resolve = contract["mustNotResolve"], !matches(resolve, .strings) { errors.append("\(path): endingContract.mustNotResolve must be a string array") }
  return errors
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-validation.ts:44
private func knowledgeContractErrors(_ value: OrderedJSON, path: String) -> [String] {
  guard let contract = value.objectValue else { return ["\(path): knowledgeContract must be an object"] }
  var errors = contract.keys.filter { !$0.jsEquals("pov") && !$0.jsEquals("learns") }.map { "\(path): unexpected field 'knowledgeContract.\($0)'" }
  let pov = contract["pov"]
  if !matches(pov, .strings) || pov?.arrayValue?.isEmpty == true || pov?.arrayValue?.contains(where: { $0.stringValue?.isEmpty == true }) == true {
    errors.append("\(path): knowledgeContract.pov must be a non-empty array of entity keys")
  }
  guard let learns = contract["learns"] else { return errors }
  guard let reveals = learns.arrayValue else { return errors + ["\(path): knowledgeContract.learns must be an array"] }
  for (index, reveal) in reveals.enumerated() {
    let at = "\(path): knowledgeContract.learns[\(index)]"
    guard let record = reveal.objectValue else {
      errors.append("\(at) must be an object")
      continue
    }
    for key in ["entityKey", "factKey"] where !isNonEmptyString(record[key]) { errors.append("\(at).\(key) must be a non-empty string") }
    errors += record.keys.filter { !$0.jsEquals("entityKey") && !$0.jsEquals("factKey") }.map { "\(at): unexpected field '\($0)'" }
  }
  return errors
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-validation.ts:74
private func passageRewriteErrors(_ record: OrderedJSONObject) -> [String] {
  var errors: [String] = []
  if case .string(let passage)? = record["passage"], passage.jsTrim().isEmpty { errors.append("passage must not be blank") }
  if let index = record["contextIndex"]?.numberValue, index < 1 { errors.append("contextIndex must be >= 1") }
  guard let anchorValue = record["anchor"] else { return errors }
  let anchor = anchorValue.objectValue ?? OrderedJSONObject([])
  let counts = anchorCounts.allSatisfy { field in matches(anchor[field], .integer) && (anchor[field]?.numberValue ?? -1) >= 0 }
  let wellFormed = anchorTexts.allSatisfy { anchor[$0]?.stringValue != nil } && counts && (anchor["end"]?.numberValue ?? 0) > (anchor["start"]?.numberValue ?? 0)
  if !wellFormed { errors.append("anchor must be {draftId, revision, saveSeq, start, end, passageHash, paragraph, contextBefore, contextAfter} with end after start") }
  return errors
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-validation.ts:89
private func normalizedBibleDocument(_ record: OrderedJSONObject) -> OrderedJSONObject {
  var section = record["section"]
  var slug = record["slug"]
  if case .string(let text)? = section, text.jsStartsWith("doc:") { section = .string(text.jsSlice(4)) }
  if case .string(let text)? = slug, text.jsStartsWith("doc:") { slug = .string(text.jsSlice(4)) }
  if case .string(let text)? = section, text.jsIncludes("/") {
    let pieces = text.jsSplit("/")
    let head = pieces.first ?? ""
    if BiblePageSection(exactly: .string(head)) != nil {
      section = .string(head)
      if slug?.stringValue == nil || slug == record["section"] || slug?.stringValue?.isEmpty == true { slug = .string(pieces.dropFirst().joined(separator: "/")) }
    }
  }
  if case .string(let sectionText)? = section, case .string(let slugText)? = slug, slugText.jsStartsWith("\(sectionText)/") {
    slug = .string(slugText.jsSlice(sectionText.jsLength + 1))
  }
  var pairs = record.entries.map { entry -> (key: String, value: OrderedJSON) in
    if entry.key.jsEquals("section"), let section { return (key: entry.key, value: section) }
    if entry.key.jsEquals("slug"), let slug { return (key: entry.key, value: slug) }
    return (key: entry.key, value: entry.value)
  }
  if record["slug"] == nil, let slug { pairs.append((key: "slug", value: slug)) }
  return OrderedJSONObject(pairs)
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-validation.ts:107
private func entityMaterializationErrors(_ items: [OrderedJSON], allowedOps: [OpType]?) -> [String] {
  if let allowedOps, !allowedOps.contains(.entityUpsert) { return [] }
  let records = items.compactMap(\.objectValue)
  let staged = Set(records.filter { $0["op"]?.stringValue?.jsEquals(OpType.entityUpsert.rawValue) == true }.map { JSString(describe($0["type"])) })
  var errors: [String] = []
  for (index, item) in items.enumerated() {
    guard let op = item.objectValue, op["op"]?.stringValue?.jsEquals(OpType.bibleDocumentUpsert.rawValue) == true else { continue }
    guard case .string(let body)? = op["body"], !body.jsTrim().isEmpty else { continue }
    let section = describe(op["section"])
    let slug = describe(op["slug"])
    let required = requiredEntityTypesForSlug(section: section, slug: slug)
    if required.isEmpty || required.contains(where: { staged.contains(JSString($0.rawValue)) }) { continue }
    errors.append(
      "changeSet[\(index)]: bible_document.upsert into '\(section)/\(slug)' establishes canon the Story Bible reads as records, so it must be accompanied by entity.upsert op(s) of type \(required.map(\.rawValue).joined(separator: " or ")) — a document body alone leaves this canon invisible"
    )
  }
  return errors
}

private func briefUpdateErrors(_ record: OrderedJSONObject, path: String) -> [String] {
  var errors: [String] = []
  if let mode = record["writeMode"], BriefWriteMode(exactly: mode) == nil { errors.append("\(path): writeMode must be one of \(joined(BriefWriteMode.self))") }
  if let contract = record["endingContract"] { errors += endingContractErrors(contract, path: path) }
  if let contract = record["knowledgeContract"], !contract.isNull { errors += knowledgeContractErrors(contract, path: path) }
  if case .string? = record["contentMode"], ContentMode(exactly: record["contentMode"]) == nil { errors.append("\(path): contentMode must be one of \(joined(ContentMode.self))") }
  if let scenes = record["scenes"], scenes.arrayValue != nil { errors += validateBriefScenes(scenes).map { "\(path): \($0)" } }
  if let milestones = record["claimedMilestones"]?.arrayValue, milestones.contains(where: isBlankOrNotString) {
    errors.append("\(path): claimedMilestones must hold non-empty milestone keys")
  }
  return errors
}

private func milestoneErrors(_ record: OrderedJSONObject, op: OpType, path: String) -> [String] {
  var errors: [String] = []
  if op == .milestoneUpsert {
    if let kind = record["kind"], MilestoneKind(exactly: kind) == nil { errors.append("\(path): kind must be one of \(joined(MilestoneKind.self))") }
    if case .string(let label)? = record["label"], label.jsTrim().isEmpty { errors.append("\(path): label must not be blank") }
  }
  if case .string(let key)? = record["milestoneKey"], !isKeyWithoutSpaces(key) { errors.append("\(path): milestoneKey must be a non-empty key without spaces") }
  return errors
}

private func factUpsertErrors(_ record: OrderedJSONObject, path: String) -> [String] {
  var errors: [String] = []
  if let chapter = record["revealChapter"]?.numberValue, chapter < 1 { errors.append("\(path): revealChapter must be >= 1") }
  if let clues = record["allowedClues"]?.arrayValue, clues.contains(where: isBlankOrNotString) { errors.append("\(path): allowedClues must hold non-empty strings") }
  if let unlock = record["unlock"], unlock.objectValue != nil { errors += validateUnlockCondition(unlock).map { "\(path): \($0)" } }
  return errors
}

private func promiseErrors(_ record: OrderedJSONObject, op: OpType, path: String) -> [String] {
  var errors: [String] = []
  if PromiseKind(exactly: record["kind"]) == nil { errors.append("\(path): kind must be one of \(joined(PromiseKind.self))") }
  if case .string(let key)? = record["key"], !isKeyWithoutSpaces(key) { errors.append("\(path): key must be a non-empty key without spaces") }
  if op == .promiseCreate, case .string(let label)? = record["label"], label.jsTrim().isEmpty { errors.append("\(path): label must not be blank") }
  if op == .promiseUpdate, let status = record["status"], PromiseOpStatus(exactly: status) == nil {
    errors.append("\(path): status must be one of \(joined(PromiseOpStatus.self))")
  }
  if op == .promiseSetPayoff, record["someday"] == .bool(true), ["payoffMilestoneKey", "payoffVolumeKey", "payoffWindow"].contains(where: { record[$0] != nil }) {
    errors.append("\(path): someday cannot be combined with payoffMilestoneKey, payoffVolumeKey or payoffWindow")
  }
  return errors
}

private func specificErrors(_ record: OrderedJSONObject, op: OpType, path: String) -> [String] {
  switch op {
  case .bibleDocumentUpsert, .bibleDocumentRemove:
    return BiblePageSection(exactly: record["section"]) == nil ? ["\(path): section must be one of \(joined(BiblePageSection.self))"] : []
  case .entityUpsert:
    return EntityType(exactly: record["type"]) == nil ? ["\(path): type must be one of \(joined(EntityType.self))"] : []
  case .briefUpdate:
    return briefUpdateErrors(record, path: path)
  case .milestoneUpsert, .milestoneRemove:
    return milestoneErrors(record, op: op, path: path)
  case .factUpsert:
    return factUpsertErrors(record, path: path)
  case .draftUpdate:
    let unset = ["title", "body", "summary"].allSatisfy { record[$0] == nil }
    return unset ? ["\(path): draft.update must set at least one of title, body, summary"] : []
  case .draftRewritePassage:
    return passageRewriteErrors(record).map { "\(path): \($0)" }
  case .actionValidate:
    return ValidationScope(exactly: record["scope"]) == nil ? ["\(path): scope must be one of \(joined(ValidationScope.self))"] : []
  case .actionGenerateChapter:
    guard let chapter = record["chapter"]?.numberValue, chapter < 1 else { return [] }
    return ["\(path): chapter must be >= 1"]
  case .promiseCreate, .promiseUpdate, .promiseSetPayoff, .promiseDrop:
    return promiseErrors(record, op: op, path: path)
  default:
    return []
  }
}

private func structuralErrors(_ record: OrderedJSONObject, op: OpType, path: String) -> [String] {
  let spec = op.spec
  var errors: [String] = []
  for field in spec.required where !matches(record[field.name], field.kind) {
    errors.append("\(path): missing or invalid required field '\(field.name)' (\(field.kind.rawValue))")
  }
  for field in spec.optional {
    guard let value = record[field.name], !matches(value, field.kind) else { continue }
    errors.append("\(path): invalid field '\(field.name)' (expected \(field.kind.rawValue))")
  }
  let declared = (spec.required + spec.optional).map(\.name) + objectPrototypeNames
  for key in record.keys where !key.jsEquals("op") && !declared.contains(where: { $0.jsEquals(key) }) { errors.append("\(path): unexpected field '\(key)'") }
  return errors
}

private func itemErrors(_ item: OrderedJSON, index: Int, allowedOps: [OpType]?) -> [String] {
  let path = "changeSet[\(index)]"
  guard let record = item.objectValue else { return ["\(path): must be an object"] }
  let opValue = record["op"]
  guard case .string(let name)? = opValue else { return ["\(path): unknown op '\(describe(opValue))'"] }
  let known = OpType(exactly: name)
  if let allowedOps, !(known.map { allowedOps.contains($0) } ?? false) {
    if known != nil || objectPrototypeNames.contains(where: { $0.jsEquals(name) }) { return ["\(path): op '\(name)' is not allowed for this scope"] }
  }
  guard let op = known else { return ["\(path): unknown op '\(name)'"] }
  return structuralErrors(record, op: op, path: path) + specificErrors(record, op: op, path: path)
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-validation.ts:139
func validateChangeSet(_ value: OrderedJSON, allowedOps: [OpType]? = nil, options: ChangeSetValidationOptions = ChangeSetValidationOptions()) -> ChangeSetValidation {
  guard case .array(let original) = value else { return ChangeSetValidation(errors: ["changeSet must be an array of operations"], value: value) }
  guard !original.isEmpty else { return ChangeSetValidation(errors: ["changeSet must contain at least one operation"], value: value) }
  let items = original.map { item -> OrderedJSON in
    guard case .object(let record) = item, case .string(let name)? = record["op"], name.jsStartsWith("bible_document") else { return item }
    return .object(normalizedBibleDocument(record))
  }
  var errors = items.enumerated().flatMap { itemErrors($1, index: $0, allowedOps: allowedOps) }
  if errors.isEmpty, options.entityMaterialization { errors += entityMaterializationErrors(items, allowedOps: allowedOps) }
  return ChangeSetValidation(errors: errors, value: .array(items))
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-validation.ts:233
func validatePluginChangeSet(_ value: OrderedJSON) -> ChangeSetValidation {
  let validation = validateChangeSet(value, allowedOps: pluginAllowedOps)
  guard case .array(let items) = validation.value else { return validation }
  var errors = validation.errors
  for (index, item) in items.enumerated() {
    guard let record = item.objectValue, record["op"]?.stringValue?.jsEquals(OpType.briefUpdate.rawValue) == true else { continue }
    for field in briefStructureFields where record[field] != nil { errors.append("changeSet[\(index)]: field '\(field)' is not allowed for this scope") }
  }
  return ChangeSetValidation(errors: errors, value: validation.value)
}
