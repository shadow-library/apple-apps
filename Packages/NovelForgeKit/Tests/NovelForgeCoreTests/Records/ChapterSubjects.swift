import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText

@testable import NovelForgeCore

let reviseMembers: Set<String> = ["body", "created", "generation", "parent", "revision", "head"]

extension Gen {
  static func chapter(_ key: String) -> Int {
    let hash = key.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    return Int(hash % 1_000_000) + 1
  }

  static func revision(_ generator: inout SeededGenerator) -> String { "v:" + generator.asciiString(maxLength: 12) }

  static func learns(_ generator: inout SeededGenerator) -> [ContractLearn] {
    (0..<generator.int(in: 0...3)).map { _ in ContractLearn(KnowledgeReveal(entityKey: text(&generator), factKey: text(&generator))) }
  }

  static func contract(_ generator: inout SeededGenerator) -> ChapterContract {
    ChapterContract(pov: texts(&generator), learns: learns(&generator), claimedMilestones: texts(&generator), isEnding: bool(&generator))
  }

  static func endingContract(_ generator: inout SeededGenerator) -> ChapterEndingContract? {
    guard !generator.chance(0.35) else { return nil }
    return ChapterEndingContract(
      hookType: stored(&generator), emotionalBeat: text(&generator), openQuestion: text(&generator), handoffState: text(&generator), mustNotResolve: optionalTexts(&generator))
  }

  static func scenes(_ generator: inout SeededGenerator) -> [PlanScene]? {
    guard !generator.chance(0.35) else { return nil }
    return (0..<generator.int(in: 0...2)).map { _ in
      PlanScene(
        BriefScene(
          summary: text(&generator), pov: optionalText(&generator), goal: optionalText(&generator), obstacle: optionalText(&generator), turn: optionalText(&generator),
          beats: optionalTexts(&generator), estimatedWords: optionalInt(&generator)))
    }
  }

  static func planContent(_ generator: inout SeededGenerator) -> ChapterPlanContent {
    ChapterPlanContent(
      title: optionalText(&generator), body: text(&generator), volume: optionalText(&generator), contextRefs: optionalTexts(&generator), pov: optionalText(&generator),
      endingContract: endingContract(&generator), contract: contract(&generator), chapterPurpose: optionalText(&generator), readerValue: optionalTexts(&generator),
      repetitionRisks: optionalTexts(&generator), densityRisk: optionalText(&generator), guidance: optionalText(&generator), direction: optionalText(&generator),
      contentMode: optionalStored(&generator), scenes: scenes(&generator), writeMode: stored(&generator), handEdited: bool(&generator), inserted: bool(&generator))
  }

  static func draftContent(_ generator: inout SeededGenerator) -> DraftContent {
    DraftContent(
      title: optionalText(&generator), body: text(&generator), summary: optionalText(&generator), source: stored(&generator), generator: stored(&generator),
      isolated: bool(&generator), restoredFrom: generator.chance(0.5) ? nil : revision(&generator), upstream: generator.chance(0.5) ? nil : upstream(&generator),
      state: generator.chance(0.5) ? nil : ["location": .string(text(&generator)), "goals": [.string(text(&generator))]],
      run: optionalText(&generator), job: generator.chance(0.5) ? nil : EntityKey(uuid: generator.uuid()))
  }

  static func upstream(_ generator: inout SeededGenerator) -> DraftUpstream {
    let first = generator.int(in: 1...4)
    let entries = (first..<(first + generator.int(in: 0...3))).map { chapter -> DraftUpstream.Entry in
      chapter == first && generator.chance(0.4)
        ? .canon(chapter: chapter, digest: generator.chance(0.2) ? nil : revision(&generator))
        : .draft(chapter: chapter, revision: generator.chance(0.2) ? nil : revision(&generator), taught: generator.chance(0.5) ? nil : revision(&generator))
    }
    return DraftUpstream(entries: entries)
  }

  static func canon(_ generator: inout SeededGenerator) -> Canon {
    Canon(
      draftRevision: revision(&generator), planRevision: revision(&generator), approval: generator.chance(0.3) ? nil : generator.uuid(), title: optionalText(&generator),
      body: text(&generator), summary: optionalText(&generator), note: optionalText(&generator), generator: stored(&generator), isolated: bool(&generator),
      volume: optionalText(&generator), contract: contract(&generator))
  }
}

private func revisionEdit<R: ChapterDocument>(
  _: R.Type, _ content: R.Body, of record: R, _ revise: @escaping @Sendable (EntityRef, R.Body, inout WriteTransaction) throws(StoreError) -> Revised
) -> SubjectEdit<R> where R.Body: Sendable {
  let ref = record.ref
  return SubjectEdit(members: reviseMembers, apply: { $0 = $0.with(content) }, perform: { transaction throws(StoreError) in try revise(ref, content, &transaction).record })
}

protocol ChapterDocument: DocumentRecord & RemovableRecord {
  func with(_ content: Body) -> Self
}

extension ChapterPlanRecord: ChapterDocument {
  func with(_ content: ChapterPlanContent) -> ChapterPlanRecord {
    var copy = self
    copy.content = content
    return copy
  }
}

extension DraftRecord: ChapterDocument {
  func with(_ content: DraftContent) -> DraftRecord {
    var copy = self
    copy.content = content
    return copy
  }
}

struct PlanSubject: RemovableSubject {
  static let requiredMembers: Set<String> = ["natural_key", "removed"]
  static let groupMember: String? = nil
  static let unknownEnum: (member: String, value: JSONValue)? = nil

  static func random(_ generator: inout SeededGenerator, novel: UUID, key: String) -> ChapterPlanRecord {
    let content = Gen.planContent(&generator)
    guard let record = try? ChapterPlanRecord(novel: novel, chapter: Gen.chapter(key), content: content) else { preconditionFailure("chapters from keys start at 1") }
    return record
  }

  static func randomEdit(_ generator: inout SeededGenerator, of record: ChapterPlanRecord) -> SubjectEdit<ChapterPlanRecord> {
    revisionEdit(ChapterPlanRecord.self, Gen.planContent(&generator), of: record) { ref, content, transaction throws(StoreError) in
      try ChapterPlanRecord.revise(ref, content, in: &transaction)
    }
  }
}

struct DraftSubject: RemovableSubject {
  static let requiredMembers: Set<String> = ["natural_key", "removed"]
  static let groupMember: String? = nil
  static let unknownEnum: (member: String, value: JSONValue)? = nil

  static func random(_ generator: inout SeededGenerator, novel: UUID, key: String) -> DraftRecord {
    let content = Gen.draftContent(&generator)
    guard let record = try? DraftRecord(novel: novel, chapter: Gen.chapter(key), content: content) else { preconditionFailure("chapters from keys start at 1") }
    return record
  }

  static func randomEdit(_ generator: inout SeededGenerator, of record: DraftRecord) -> SubjectEdit<DraftRecord> {
    revisionEdit(DraftRecord.self, Gen.draftContent(&generator), of: record) { ref, content, transaction throws(StoreError) in
      try DraftRecord.revise(ref, content, in: &transaction)
    }
  }
}
