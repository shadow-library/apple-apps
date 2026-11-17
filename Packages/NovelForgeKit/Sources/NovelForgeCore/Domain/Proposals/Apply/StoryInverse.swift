import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/refinement/apply/premise.handler.ts:9-11 and the fields of the projects row each one restores
enum PremiseField: String, CaseIterable, Sendable {
  case premise
  case brief
  case themes
  case instructions
  case theme
  case readerPromise
  case protagonistKey
  case opposition
  case endingQuestion
  case ending

  func stored(in novel: NovelRecord) -> OrderedJSON {
    switch self {
    case .premise: optionalText(novel.premise)
    case .brief: optionalText(novel.brief)
    case .themes: optionalList(novel.themes)
    case .instructions: optionalText(novel.writingStyle)
    case .theme: optionalText(novel.theme)
    case .readerPromise: optionalText(novel.readerPromise)
    case .protagonistKey: optionalText(novel.protagonist)
    case .opposition: optionalText(novel.opposition)
    case .endingQuestion: optionalText(novel.endingQuestion)
    case .ending: optionalText(novel.ending)
    }
  }

  func restore(_ value: OrderedJSON, into edit: inout NovelEdit) throws(ApplyRefusal) {
    if self == .themes {
      edit.themes = .set(try nullable(value, strings))
      return
    }
    let text = try nullable(value, \.stringValue)
    switch self {
    case .premise: edit.premise = .set(text)
    case .brief: edit.brief = .set(text)
    case .themes: return
    case .instructions: edit.writingStyle = .set(text)
    case .theme: edit.theme = .set(text)
    case .readerPromise: edit.readerPromise = .set(text)
    case .protagonistKey: edit.protagonist = .set(text)
    case .opposition: edit.opposition = .set(text)
    case .endingQuestion: edit.endingQuestion = .set(text)
    case .ending: edit.ending = .set(text)
    }
  }
}

struct VolumeRestore: Sendable, Equatable {
  let volume: String
  let ordinal: Int
  let title: String?
  let objective: String?
  let body: String?

  init(_ record: VolumeRecord, key: String) {
    volume = key
    ordinal = record.ordinal
    title = record.title
    objective = record.objective
    body = record.body
  }

  fileprivate init(_ fields: OrderedJSONObject) throws(ApplyRefusal) {
    volume = try required(fields, "volumeKey", \.stringValue)
    ordinal = try required(fields, "ordinal", exactInt)
    title = try nullable(fields, "title", \.stringValue)
    objective = try nullable(fields, "objective", \.stringValue)
    body = try nullable(fields, "body", \.stringValue)
  }

  // volume.handler.ts:16
  var json: OrderedJSONObject {
    inverse(
      .volumeUpsert,
      [
        ("volumeKey", .string(volume)), ("ordinal", optionalNumber(ordinal)), ("title", optionalText(title)), ("objective", optionalText(objective)),
        ("body", optionalText(body)),
      ])
  }
}

/// A milestone's reached and planned states are derived from the chapters that claim it, so only its authored fields come back (milestone.handler.ts:22).
struct MilestoneRestore: Sendable, Equatable {
  let milestone: String
  let label: String
  let subject: String?
  let kind: StoredEnum<MilestoneKind>

  init(_ record: MilestoneRecord, key: String) {
    milestone = key
    label = record.label
    subject = record.subject
    kind = record.kind
  }

  fileprivate init(_ fields: OrderedJSONObject) throws(ApplyRefusal) {
    milestone = try required(fields, "milestoneKey", \.stringValue)
    label = try required(fields, "label", \.stringValue)
    subject = try nullable(fields, "subjectEntityKey", \.stringValue)
    kind = StoredEnum(rawValue: try required(fields, "kind", \.stringValue))
  }

  var json: OrderedJSONObject {
    inverse(.milestoneUpsert, [("milestoneKey", .string(milestone)), ("label", .string(label)), ("subjectEntityKey", optionalText(subject)), ("kind", .string(kind.rawValue))])
  }
}

/// Every field explicit (fact.handler.ts:24): an omitted one would merge as "keep". A missing writer note is null rather than the reference's empty string, so
/// an empty note comes back empty.
struct FactRestore: Sendable, Equatable {
  let fact: String
  let text: String
  let subjects: [String]?
  let constraintNote: String?
  let writerNote: String?
  let terms: [String]?
  let revealChapter: Int?
  let unlock: JSONValue?
  let allowedClues: [String]?

  init(_ record: SecretRecord, key: String) {
    fact = key
    text = record.text
    subjects = record.subjects
    constraintNote = record.constraintNote
    writerNote = record.writerNote
    terms = record.cluesAndTerms?.terms
    revealChapter = record.revealChapter
    unlock = record.unlock
    allowedClues = record.cluesAndTerms?.clues
  }

  fileprivate init(_ fields: OrderedJSONObject) throws(ApplyRefusal) {
    fact = try required(fields, "factKey", \.stringValue)
    text = try required(fields, "body", \.stringValue)
    subjects = try nullable(fields, "subjects", strings)
    constraintNote = try nullable(fields, "constraintNote", \.stringValue)
    writerNote = try nullable(fields, "writerNote", \.stringValue)
    terms = try nullable(fields, "terms", strings)
    revealChapter = try nullable(fields, "revealChapter", exactInt)
    unlock = try nullable(fields, "unlock", storyJSONValue)
    allowedClues = try nullable(fields, "allowedClues", strings)
  }

  // fact.handler.ts:16
  var json: OrderedJSONObject {
    inverse(
      .factUpsert,
      [
        ("factKey", .string(fact)), ("body", .string(text)), ("subjects", optionalList(subjects)), ("constraintNote", optionalText(constraintNote)),
        ("writerNote", optionalText(writerNote)), ("terms", optionalList(terms)), ("revealChapter", optionalNumber(revealChapter)),
        ("unlock", unlock.map(OrderedJSON.init) ?? .null), ("allowedClues", optionalList(allowedClues)),
      ])
  }
}

/// promise.handler.ts:13-19: the label, status and paid-off chapter a promise.update or drop changes; the last advanced chapter has no native field.
struct PromiseRestore: Sendable, Equatable {
  let promise: PromiseRef
  let label: String?
  let status: String
  let chapter: Int?

  init(_ thread: ThreadRecord, promise: PromiseRef) {
    self.promise = promise
    label = thread.summary
    status = thread.status.state.rawValue
    chapter = thread.status.chapter
  }

  init(_ mystery: MysteryRecord, promise: PromiseRef) {
    self.promise = promise
    label = mystery.question
    status = mystery.status.state.rawValue
    chapter = mystery.status.chapter
  }

  fileprivate init(_ promise: PromiseRef, _ fields: OrderedJSONObject) throws(ApplyRefusal) {
    self.promise = promise
    label = try nullable(fields, "restoreLabel", \.stringValue)
    status = try required(fields, "restoreStatus", \.stringValue)
    chapter = try nullable(fields, "restoreChapterColumn", exactInt)
  }

  // promise.handler.ts:100
  var json: OrderedJSONObject {
    inverse(.promiseUpdate, promiseKey(promise) + [("restoreLabel", optionalText(label)), ("restoreStatus", .string(status)), ("restoreChapterColumn", optionalNumber(chapter))])
  }
}

struct PayoffRestore: Sendable, Equatable {
  let promise: PromiseRef
  let milestone: String?
  let volume: String?
  let window: Int?
  let dormant: Bool

  init(promise: PromiseRef, milestone: String?, volume: String?, window: Int?, dormant: Bool) {
    self.promise = promise
    self.milestone = milestone
    self.volume = volume
    self.window = window
    self.dormant = dormant
  }

  fileprivate init(_ promise: PromiseRef, _ fields: OrderedJSONObject) throws(ApplyRefusal) {
    self.promise = promise
    milestone = try nullable(fields, "payoffMilestoneKey", \.stringValue)
    volume = try nullable(fields, "payoffVolumeKey", \.stringValue)
    window = try nullable(fields, "payoffWindow", exactInt)
    dormant = try required(fields, "dormant", flag)
  }

  // promise.handler.ts:89
  var json: OrderedJSONObject {
    inverse(
      .promiseSetPayoff,
      promiseKey(promise) + [
        ("payoffMilestoneKey", optionalText(milestone)), ("payoffVolumeKey", optionalText(volume)), ("payoffWindow", optionalNumber(window)), ("dormant", .bool(dormant)),
      ])
  }
}

/// What undoes a story change: the record written back with the content it held, or removed when the change created it.
enum StoryRestore: Sendable, Equatable {
  case premise([(field: PremiseField, value: OrderedJSON)])
  case volume(VolumeRestore)
  case volumeRemoval(String)
  case milestone(MilestoneRestore)
  case milestoneRemoval(String)
  case fact(FactRestore)
  case factRemoval(String)
  case promise(PromiseRestore)
  case payoff(PayoffRestore)
  case promiseDeletion(PromiseRef)

  static func == (left: StoryRestore, right: StoryRestore) -> Bool {
    left.json == right.json
  }

  init(_ fields: OrderedJSONObject) throws(ApplyRefusal) {
    guard let type = fields["op"]?.stringValue.flatMap({ OpType(exactly: $0) }) else { throw .malformedInverse }
    switch type {
    case .premiseUpdate:
      let named = PremiseField.allCases.compactMap { field in fields[field.rawValue].map { (field: field, value: $0) } }
      var checked = NovelEdit()
      for (field, value) in named { try field.restore(value, into: &checked) }
      self = .premise(named)
    case .volumeUpsert: self = .volume(try VolumeRestore(fields))
    case .volumeRemove: self = .volumeRemoval(try required(fields, "volumeKey", \.stringValue))
    case .milestoneUpsert: self = .milestone(try MilestoneRestore(fields))
    case .milestoneRemove: self = .milestoneRemoval(try required(fields, "milestoneKey", \.stringValue))
    case .factUpsert: self = .fact(try FactRestore(fields))
    case .factRemove: self = .factRemoval(try required(fields, "factKey", \.stringValue))
    case .promiseUpdate: self = .promise(try PromiseRestore(try promiseRef(fields), fields))
    case .promiseSetPayoff: self = .payoff(try PayoffRestore(try promiseRef(fields), fields))
    case .promiseDrop:
      guard case .bool(true)? = fields["hardDelete"] else { throw .malformedInverse }
      self = .promiseDeletion(try promiseRef(fields))
    default: throw .malformedInverse
    }
  }

  var json: OrderedJSONObject {
    switch self {
    case .premise(let fields): inverse(.premiseUpdate, fields.map { ($0.field.rawValue, $0.value) })
    case .volume(let restore): restore.json
    case .volumeRemoval(let key): inverse(.volumeRemove, [("volumeKey", .string(key))])
    case .milestone(let restore): restore.json
    case .milestoneRemoval(let key): inverse(.milestoneRemove, [("milestoneKey", .string(key))])
    case .fact(let restore): restore.json
    case .factRemoval(let key): inverse(.factRemove, [("factKey", .string(key))])
    case .promise(let restore): restore.json
    case .payoff(let restore): restore.json
    // promise.handler.ts:85: a drop that deletes, since the promise did not exist before the change
    case .promiseDeletion(let promise): inverse(.promiseDrop, promiseKey(promise) + [("hardDelete", .bool(true))])
    }
  }
}

private func inverse(_ type: OpType, _ pairs: [(String, OrderedJSON)]) -> OrderedJSONObject {
  jsonRecord([("op", .string(type.rawValue))] + pairs)
}

private func promiseKey(_ promise: PromiseRef) -> [(String, OrderedJSON)] {
  [("kind", .string(promise.kindName)), ("key", .string(promise.key))]
}

private func promiseRef(_ fields: OrderedJSONObject) throws(ApplyRefusal) -> PromiseRef {
  let key = try required(fields, "key", \.stringValue)
  switch PromiseKind(exactly: fields["kind"]) {
  case .thread?: return .thread(key)
  case .mystery?: return .mystery(key)
  case nil: throw .malformedInverse
  }
}

private func required<Value>(_ fields: OrderedJSONObject, _ key: String, _ convert: (OrderedJSON) -> Value?) throws(ApplyRefusal) -> Value {
  guard let value = fields[key].flatMap(convert) else { throw .malformedInverse }
  return value
}

private func nullable<Value>(_ fields: OrderedJSONObject, _ key: String, _ convert: (OrderedJSON) -> Value?) throws(ApplyRefusal) -> Value? {
  guard let value = fields[key] else { throw .malformedInverse }
  return try nullable(value, convert)
}

private func nullable<Value>(_ value: OrderedJSON, _ convert: (OrderedJSON) -> Value?) throws(ApplyRefusal) -> Value? {
  if value.isNull { return nil }
  guard let converted = convert(value) else { throw .malformedInverse }
  return converted
}

private func strings(_ value: OrderedJSON) -> [String]? {
  guard let items = value.arrayValue else { return nil }
  let texts = items.compactMap(\.stringValue)
  return texts.count == items.count ? texts : nil
}

private func exactInt(_ value: OrderedJSON) -> Int? {
  guard case .int(let number) = value else { return nil }
  return Int(exactly: number)
}

private func flag(_ value: OrderedJSON) -> Bool? {
  guard case .bool(let flag) = value else { return nil }
  return flag
}

/// The stored form of a captured JSON value; nil for a fraction, which a store value never holds.
func storyJSONValue(_ value: OrderedJSON) -> JSONValue? {
  switch value {
  case .null: return .null
  case .bool(let flag): return .bool(flag)
  case .int(let number): return .int(number)
  case .double(let number): return Int64(exactly: number).map(JSONValue.int)
  case .string(let text): return .string(text)
  case .array(let items):
    let converted = items.compactMap(storyJSONValue)
    return converted.count == items.count ? .array(converted) : nil
  case .object(let record):
    var members = [String: JSONValue]()
    for entry in record.entries {
      guard let member = storyJSONValue(entry.value) else { return nil }
      members[entry.key] = member
    }
    return .object(members)
  }
}
