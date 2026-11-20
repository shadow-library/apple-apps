import Foundation
import ShadowCore
import ShadowStore
import ShadowText

@testable import NovelForgeCore

struct ArtifactStateWorld {
  let novel = SchemaFixture.novel
  private let root: OrderedJSONObject

  init(_ root: OrderedJSONObject) {
    self.root = root
  }

  static func load() throws -> [ArtifactStateWorld] {
    let data = try ReferenceFixture.data("artifact-state/worlds.json")
    let parsed = try OrderedJSON(parsing: String(decoding: data, as: UTF8.self))
    return (parsed.objectValue?["worlds"]?.arrayValue ?? []).compactMap { $0.objectValue.map(ArtifactStateWorld.init) }
  }

  func rows(_ table: String) -> [OrderedJSONObject] { root["tables"]?.objectValue?[table]?.arrayValue?.compactMap(\.objectValue) ?? [] }

  var refs: [String] { root["refs"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
  var changeSetText: String { root["changeSet"]?.stringValue ?? "[]" }
  var currentRefs: [String] { root["currentRefs"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
  var expectedStates: [(ref: String, exists: Bool, hash: String?)] {
    (root["states"]?.arrayValue ?? []).compactMap { entry in
      guard let items = entry.arrayValue, items.count == 3, let ref = items[0].stringValue, case .bool(let exists) = items[1] else { return nil }
      return (ref, exists, items[2].stringValue)
    }
  }
  var expectedCurrent: [(ref: String, fields: OrderedJSONObject)] {
    (root["current"]?.arrayValue ?? []).compactMap { entry in
      guard let items = entry.arrayValue, items.count == 2, let ref = items[0].stringValue, let fields = items[1].objectValue else { return nil }
      return (ref, fields)
    }
  }
  var expectedProposalCurrent: [ProposalOpCurrent] {
    (root["proposalCurrent"]?.arrayValue ?? []).compactMap { entry in
      guard let item = entry.objectValue, case .int(let index)? = item["index"], case .bool(let exists)? = item["exists"], let values = item["values"]?.objectValue else {
        return nil
      }
      return ProposalOpCurrent(index: Int(index), exists: exists, values: values)
    }
  }
  var statelessVolumeHash: [String: String] {
    Dictionary(uniqueKeysWithValues: (root["statelessVolumeHash"]?.objectValue?.entries ?? []).compactMap { entry in entry.value.stringValue.map { (entry.key, $0) } })
  }

  func records() throws -> [any NovelForgeRecord] {
    var records: [any NovelForgeRecord] = []
    if let project = rows("projects").first { records.append(novelRecord(project)) }
    for row in rows("bibleDocuments") {
      let section = BiblePageSection.allCases.first { $0.rawValue == row.string("section") } ?? .world
      let content = PageContent(frontmatter: row.json("frontmatter")?.objectValue, body: row.string("body"))
      records.append(PageRecord(novel: novel, section: section, slug: row.string("slug") ?? "", content: content))
    }
    for row in rows("volumes") {
      records.append(
        VolumeRecord(
          novel: novel, volume: row.string("volumeKey") ?? "", ordinal: row.int("ordinal") ?? 0, title: row.string("title"), objective: row.string("objective"),
          body: row.string("body"), goalMet: row.string("state") == "goal_met"))
    }
    for row in rows("briefs") { records.append(try plan(row)) }
    for row in rows("drafts") {
      let content = DraftContent(title: row.string("title"), body: row.string("body") ?? "", summary: row.string("summary"), source: .known(.generated))
      records.append(try DraftRecord(novel: novel, chapter: row.int("chapter") ?? 1, content: content))
    }
    for row in rows("entities") {
      records.append(
        EntityRecord(
          novel: novel, entity: row.string("entityKey") ?? "", type: StoredEnum(rawValue: row.string("type") ?? ""), name: row.string("name") ?? "", status: row.string("status"),
          notes: row.string("notes"), motivation: row.string("motivation"), body: row.string("body")))
    }
    for row in rows("canonFacts") { records.append(secret(row)) }
    for row in rows("milestones") {
      records.append(
        MilestoneRecord(
          novel: novel, milestone: row.string("milestoneKey") ?? "", label: row.string("label") ?? "", subject: row.string("subjectEntityKey"),
          kind: StoredEnum(rawValue: row.string("kind") ?? "")))
    }
    for row in rows("plotThreads") {
      records.append(
        ThreadRecord(
          novel: novel, thread: row.string("threadKey") ?? "", summary: row.string("summary"),
          status: ThreadProgress(state: StoredEnum(rawValue: row.string("status") ?? ""), chapter: row.int("closedChapter")), payoffWindow: row.int("payoffWindow"),
          payoffMilestone: row.string("payoffMilestoneKey"), payoffVolume: row.string("payoffVolumeKey"), dormant: row.bool("intentionallyOpen")))
    }
    for row in rows("mysteries") {
      records.append(
        MysteryRecord(
          novel: novel, mystery: row.string("mysteryKey") ?? "", question: row.string("question") ?? "",
          status: MysteryProgress(state: StoredEnum(rawValue: row.string("status") ?? ""), chapter: row.int("resolvedChapter")), payoffWindow: row.int("payoffWindow"),
          payoffMilestone: row.string("payoffMilestoneKey"), payoffVolume: row.string("payoffVolumeKey"), dormant: row.bool("intentionallyOpen")))
    }
    return records
  }

  private func novelRecord(_ row: OrderedJSONObject) -> NovelRecord {
    NovelRecord(
      id: novel, name: "Ember", brief: row.string("brief"), premise: row.string("premise"), themes: row.strings("themes"), theme: row.string("theme"),
      endingQuestion: row.string("endingQuestion"), ending: row.string("ending"), readerPromise: row.string("readerPromise"), protagonist: row.string("protagonistKey"),
      opposition: row.string("opposition"), writingStyle: row.string("instructions"))
  }

  private func secret(_ row: OrderedJSONObject) -> SecretRecord {
    let clues = row.strings("allowedClues")
    let terms = row.strings("terms")
    return SecretRecord(
      novel: novel, secret: row.string("factKey") ?? "", text: row.string("text") ?? "", subjects: row.strings("subjects"), constraintNote: row.string("constraintNote"),
      writerNote: row.string("writerNote"), cluesAndTerms: clues == nil && terms == nil ? nil : CluesAndTerms(clues: clues, terms: terms), revealChapter: row.int("revealChapter"),
      unlock: row.json("unlock"))
  }

  private func plan(_ row: OrderedJSONObject) throws -> ChapterPlanRecord {
    let ending = row["endingContract"]?.objectValue.map { contract in
      ChapterEndingContract(
        hookType: StoredEnum(rawValue: contract.string("hookType") ?? ""), emotionalBeat: contract.string("emotionalBeat") ?? "",
        openQuestion: contract.string("openQuestion") ?? "",
        handoffState: contract.string("handoffState") ?? "", mustNotResolve: contract.strings("mustNotResolve"))
    }
    let knowledge = row["knowledgeContract"]?.objectValue
    let learns = (knowledge?["learns"]?.arrayValue ?? []).compactMap { $0.objectValue }.map {
      ContractLearn(KnowledgeReveal(entityKey: $0.string("entityKey") ?? "", factKey: $0.string("factKey") ?? ""))
    }
    let contract = ChapterContract(pov: knowledge?.strings("pov") ?? [], learns: learns, claimedMilestones: row.strings("claimedMilestones") ?? [], isEnding: row.bool("isEnding"))
    let scenes = row["scenes"]?.arrayValue?.compactMap { $0.objectValue }.map { scene in
      PlanScene(
        BriefScene(
          summary: scene.string("summary") ?? "", pov: scene.string("pov"), goal: scene.string("goal"), obstacle: scene.string("obstacle"), turn: scene.string("turn"),
          beats: scene.strings("beats"), estimatedWords: scene.int("estimatedWords")))
    }
    let content = ChapterPlanContent(
      title: row.string("title"), body: row.string("body") ?? "", volume: row.string("volumeKey"), contextRefs: row.strings("contextRefs"), pov: row.string("pov"),
      endingContract: ending, contract: contract, chapterPurpose: row.string("chapterPurpose"), readerValue: row.strings("readerValue"),
      repetitionRisks: row.strings("repetitionRisks"), guidance: row.string("guidance"), direction: row.string("direction"),
      contentMode: row.string("contentMode").map { StoredEnum(rawValue: $0) }, scenes: scenes)
    return try ChapterPlanRecord(novel: novel, chapter: row.int("chapter") ?? 1, content: content)
  }
}

extension OrderedJSONObject {
  func json(_ key: String) -> JSONValue? {
    guard let value = self[key], !value.isNull else { return nil }
    return jsonValue(value)
  }

  func string(_ key: String) -> String? { self[key]?.stringValue }

  func int(_ key: String) -> Int? { self[key]?.numberValue.map { Int($0) } }

  func bool(_ key: String) -> Bool {
    guard case .bool(let flag)? = self[key] else { return false }
    return flag
  }

  func strings(_ key: String) -> [String]? { self[key]?.arrayValue?.compactMap(\.stringValue) }
}

func jsonValue(_ value: OrderedJSON) -> JSONValue {
  switch value {
  case .null, .double: .null
  case .bool(let flag): .bool(flag)
  case .int(let number): .int(number)
  case .string(let text): .string(text)
  case .array(let items): .array(items.map(jsonValue))
  case .object(let object): .object(Dictionary(object.entries.map { ($0.key, jsonValue($0.value)) }) { first, _ in first })
  }
}
