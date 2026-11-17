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
      edit.themes = .set(try InverseMembers.nullable(value, inverseStrings))
      return
    }
    let text = try InverseMembers.nullable(value, \.stringValue)
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
    let members = InverseMembers(fields)
    volume = try members.required("volumeKey", \.stringValue)
    ordinal = try members.required("ordinal", inverseInt)
    title = try members.nullable("title", \.stringValue)
    objective = try members.nullable("objective", \.stringValue)
    body = try members.nullable("body", \.stringValue)
  }

  // volume.handler.ts:16
  var json: OrderedJSONObject {
    inverseOp(
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
    let members = InverseMembers(fields)
    milestone = try members.required("milestoneKey", \.stringValue)
    label = try members.required("label", \.stringValue)
    subject = try members.nullable("subjectEntityKey", \.stringValue)
    kind = StoredEnum(rawValue: try members.required("kind", \.stringValue))
  }

  var json: OrderedJSONObject {
    inverseOp(.milestoneUpsert, [("milestoneKey", .string(milestone)), ("label", .string(label)), ("subjectEntityKey", optionalText(subject)), ("kind", .string(kind.rawValue))])
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
    let members = InverseMembers(fields)
    fact = try members.required("factKey", \.stringValue)
    text = try members.required("body", \.stringValue)
    subjects = try members.nullable("subjects", inverseStrings)
    constraintNote = try members.nullable("constraintNote", \.stringValue)
    writerNote = try members.nullable("writerNote", \.stringValue)
    terms = try members.nullable("terms", inverseStrings)
    revealChapter = try members.nullable("revealChapter", inverseInt)
    unlock = try members.nullable("unlock", \.storable)
    allowedClues = try members.nullable("allowedClues", inverseStrings)
  }

  // fact.handler.ts:16
  var json: OrderedJSONObject {
    inverseOp(
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
    let members = InverseMembers(fields)
    self.promise = promise
    label = try members.nullable("restoreLabel", \.stringValue)
    status = try members.required("restoreStatus", \.stringValue)
    chapter = try members.nullable("restoreChapterColumn", inverseInt)
  }

  // promise.handler.ts:100
  var json: OrderedJSONObject {
    inverseOp(.promiseUpdate, promiseKey(promise) + [("restoreLabel", optionalText(label)), ("restoreStatus", .string(status)), ("restoreChapterColumn", optionalNumber(chapter))])
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
    let members = InverseMembers(fields)
    self.promise = promise
    milestone = try members.nullable("payoffMilestoneKey", \.stringValue)
    volume = try members.nullable("payoffVolumeKey", \.stringValue)
    window = try members.nullable("payoffWindow", inverseInt)
    dormant = try members.required("dormant", inverseBool)
  }

  // promise.handler.ts:89
  var json: OrderedJSONObject {
    inverseOp(
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
    case .volumeRemove: self = .volumeRemoval(try InverseMembers(fields).required("volumeKey", \.stringValue))
    case .milestoneUpsert: self = .milestone(try MilestoneRestore(fields))
    case .milestoneRemove: self = .milestoneRemoval(try InverseMembers(fields).required("milestoneKey", \.stringValue))
    case .factUpsert: self = .fact(try FactRestore(fields))
    case .factRemove: self = .factRemoval(try InverseMembers(fields).required("factKey", \.stringValue))
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
    case .premise(let fields): inverseOp(.premiseUpdate, fields.map { ($0.field.rawValue, $0.value) })
    case .volume(let restore): restore.json
    case .volumeRemoval(let key): inverseOp(.volumeRemove, [("volumeKey", .string(key))])
    case .milestone(let restore): restore.json
    case .milestoneRemoval(let key): inverseOp(.milestoneRemove, [("milestoneKey", .string(key))])
    case .fact(let restore): restore.json
    case .factRemoval(let key): inverseOp(.factRemove, [("factKey", .string(key))])
    case .promise(let restore): restore.json
    case .payoff(let restore): restore.json
    // promise.handler.ts:85: a drop that deletes, since the promise did not exist before the change
    case .promiseDeletion(let promise): inverseOp(.promiseDrop, promiseKey(promise) + [("hardDelete", .bool(true))])
    }
  }
}

private func promiseKey(_ promise: PromiseRef) -> [(String, OrderedJSON)] {
  [("kind", .string(promise.kindName)), ("key", .string(promise.key))]
}

private func promiseRef(_ fields: OrderedJSONObject) throws(ApplyRefusal) -> PromiseRef {
  let key = try InverseMembers(fields).required("key", \.stringValue)
  switch PromiseKind(exactly: fields["kind"]) {
  case .thread?: return .thread(key)
  case .mystery?: return .mystery(key)
  case nil: throw .malformedInverse
  }
}
