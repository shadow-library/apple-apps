import Foundation
import ShadowCore
import ShadowStore
import ShadowText

enum CurrentRecord: Sendable, Equatable {
  case fields(OrderedJSONObject)
  case unreadable

  var fields: OrderedJSONObject? {
    guard case .fields(let fields) = self else { return nil }
    return fields
  }
}

struct CurrentRecords: Sendable, Equatable {
  private let byRef: [JSString: OrderedJSONObject]
  let unreadable: Set<JSString>

  init(_ entries: [(ref: String, fields: OrderedJSONObject)] = [], unreadable: Set<JSString> = []) {
    byRef = Dictionary(entries.map { (JSString($0.ref), $0.fields) }) { _, last in last }
    self.unreadable = unreadable
  }

  subscript(ref: String) -> CurrentRecord? {
    if unreadable.contains(JSString(ref)) { return .unreadable }
    return byRef[JSString(ref)].map(CurrentRecord.fields)
  }

  func exists(_ ref: String) -> Bool { self[ref] != nil }
}

enum ArtifactStateLoader {
  // artifact-state.ts:77
  static func states<Transaction: StateReading & ~Copyable>(refs: [String], novel: UUID, in transaction: borrowing Transaction) throws(StoreError) -> [JSString: ArtifactState] {
    var states = [JSString: ArtifactState]()
    for ref in refs {
      states[JSString(ref)] = .missing
      guard let parsed = ArtifactRef(ref) else { continue }
      switch try ArtifactSubject.read(parsed, novel: novel, in: transaction) {
      case .missing: continue
      case .unreadable: states[JSString(ref)] = .unreadable
      case .present(let subject): states[JSString(ref)] = ArtifactState(exists: true, revision: nil, contentHash: subject.contentHash)
      }
    }
    return states
  }

  // artifact-state.ts:228: existing refs mapped to the fields an op of their kind writes; chapters and drafts need only existence
  static func currentRecords<Transaction: StateReading & ~Copyable>(refs: [String], novel: UUID, in transaction: borrowing Transaction) throws(StoreError) -> CurrentRecords {
    var subjects = [(ref: String, subject: ArtifactSubject)]()
    var unreadable = Set<JSString>()
    for ref in refs {
      guard let parsed = ArtifactRef(ref) else { continue }
      switch try ArtifactSubject.read(parsed, novel: novel, in: transaction) {
      case .missing: continue
      case .unreadable: unreadable.insert(JSString(ref))
      case .present(let subject): subjects.append((ref, subject))
      }
    }
    var volumeStates = [JSString: VolumeState]()
    if subjects.contains(where: { if case .volume = $0.subject { true } else { false } }) {
      for standing in volumeStandings(of: try VolumeRecord.listing(novel: novel, in: transaction).live) { volumeStates[JSString(standing.volume)] = standing.state }
    }
    return CurrentRecords(subjects.map { (ref: $0.ref, fields: $0.subject.currentFields(volumeStates: volumeStates)) }, unreadable: unreadable)
  }
}

extension ArtifactSubject {
  fileprivate func currentFields(volumeStates: [JSString: VolumeState]) -> OrderedJSONObject {
    switch self {
    case .premise(let novel):
      jsonRecord([
        ("premise", optionalText(novel.premise)), ("brief", optionalText(novel.brief)), ("themes", optionalList(novel.themes)), ("instructions", optionalText(novel.writingStyle)),
        ("theme", optionalText(novel.theme)), ("readerPromise", optionalText(novel.readerPromise)), ("protagonistKey", optionalText(novel.protagonist)),
        ("opposition", optionalText(novel.opposition)),
        ("endingQuestion", optionalText(novel.endingQuestion)), ("ending", optionalText(novel.ending)),
      ])
    case .doc(let page):
      jsonRecord([("body", optionalText(page.content.body)), ("frontmatter", page.content.frontmatter.map { OrderedJSON(.object($0)) } ?? .null)])
    case .volume(let volume):
      jsonRecord([
        ("ordinal", optionalNumber(volume.ordinal)), ("title", optionalText(volume.title)), ("objective", optionalText(volume.objective)), ("body", optionalText(volume.body)),
        ("state", .string((volumeStates[JSString(volume.volume)] ?? .notStarted).rawValue)),
      ])
    case .chapter, .draft:
      jsonRecord([])
    case .entity(let entity):
      jsonRecord([
        ("type", .string(entity.type.rawValue)), ("name", .string(entity.name)), ("status", optionalText(entity.status)), ("motivation", optionalText(entity.motivation)),
        ("notes", optionalText(entity.notes)), ("body", optionalText(entity.body)),
      ])
    case .fact(let fact):
      jsonRecord([
        ("body", .string(fact.text)), ("subjects", optionalList(fact.subjects)), ("constraintNote", optionalText(fact.constraintNote)),
        ("writerNote", optionalText(fact.writerNote)),
        ("terms", optionalList(fact.cluesAndTerms?.terms)), ("revealChapter", optionalNumber(fact.revealChapter)), ("unlock", fact.unlock.map { OrderedJSON($0) } ?? .null),
        ("allowedClues", optionalList(fact.cluesAndTerms?.clues)),
      ])
    case .milestone(let milestone):
      jsonRecord([("label", .string(milestone.label)), ("subjectEntityKey", optionalText(milestone.subject)), ("kind", .string(milestone.kind.rawValue))])
    case .thread(let thread):
      promiseFields(
        label: thread.summary, status: thread.status.state.rawValue, payoffWindow: thread.payoffWindow, milestone: thread.payoffMilestone, volume: thread.payoffVolume,
        dormant: thread.dormant)
    case .mystery(let mystery):
      promiseFields(
        label: mystery.question, status: mystery.status.state.rawValue, payoffWindow: mystery.payoffWindow, milestone: mystery.payoffMilestone, volume: mystery.payoffVolume,
        dormant: mystery.dormant)
    }
  }
}

// artifact-state.ts:215; lastAdvancedChapter is observed by the pipeline and has no v1 record
private func promiseFields(label: String?, status: String, payoffWindow: Int?, milestone: String?, volume: String?, dormant: Bool) -> OrderedJSONObject {
  jsonRecord([
    ("label", optionalText(label)), ("lastAdvancedChapter", .null), ("status", .string(status)), ("payoffMilestoneKey", optionalText(milestone)),
    ("payoffVolumeKey", optionalText(volume)),
    ("payoffWindow", optionalNumber(payoffWindow)), ("dormant", .bool(dormant)),
  ])
}
