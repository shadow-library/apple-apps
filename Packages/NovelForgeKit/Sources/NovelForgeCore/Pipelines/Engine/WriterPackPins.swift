import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

/// The pack an attempt built, as it was built: the reference builds the context once per run (context-assembler.service.ts:193) and later steps read it, and
/// scrub with the same disclosure policy (chapter-generation.graph.ts:490-494, 531-534, 739-762, 816-833). The policy is kept as the sources it was built from.
/// A pinned row this version cannot decode is rebuilt mid-attempt, so every change to this shape raises the pipeline version.
struct PinnedWriterPack: Codable, Equatable, Sendable {
  struct Reservation: Codable, Equatable, Sendable {
    let name: String
    let tokens: Int
    let cap: Int
    let fromPlan: Bool
  }

  struct Withheld: Codable, Equatable, Sendable {
    let field: String
    let count: Int
  }

  let chapter: Int
  let budgetTokens: Int
  let usedTokens: Int
  let sections: [ChatPackSection]
  let unresolvedRefs: [String]
  let withheldRefs: [String]
  let omitted: [ChatPackOmission]
  let renderedStable: String
  let renderedVolatile: String
  let rendered: String
  let chapterBrief: String
  let endingContract: String
  let reservations: [Reservation]
  let withheld: [Withheld]
  let disclosure: PinnedDisclosureSources

  init(_ pack: WriterPack, disclosure: WriterDisclosurePolicy, sources: WriterDisclosureSources) {
    chapter = pack.chapter
    budgetTokens = pack.budgetTokens
    usedTokens = pack.usedTokens
    sections = pack.sections
    unresolvedRefs = pack.unresolvedRefs
    withheldRefs = pack.withheldRefs
    omitted = pack.omitted
    renderedStable = pack.renderedStable
    renderedVolatile = pack.renderedVolatile
    rendered = pack.rendered
    chapterBrief = pack.brief.chapterBrief
    endingContract = pack.brief.endingContract
    reservations = pack.reservations.map { Reservation(name: $0.name, tokens: $0.tokens, cap: $0.cap, fromPlan: $0.fromPlan) }
    withheld = disclosure.withheld.map { Withheld(field: $0.field.rawValue, count: $0.count) }
    self.disclosure = PinnedDisclosureSources(sources)
  }

  /// The policy the pack was scrubbed by, rebuilt from its sources on every call, so each step starts from the build's withholdings.
  func disclosurePolicy() throws(DisclosureError) -> WriterDisclosurePolicy {
    try writerDisclosurePolicy(disclosure.sources)
  }

  var pack: WriterPack {
    WriterPack(
      chapter: chapter, budgetTokens: budgetTokens, usedTokens: usedTokens, sections: sections, unresolvedRefs: unresolvedRefs, withheldRefs: withheldRefs,
      omitted: omitted, renderedStable: renderedStable, renderedVolatile: renderedVolatile, rendered: rendered,
      brief: WriterBrief(chapterBrief: chapterBrief, endingContract: endingContract),
      reservations: reservations.map { WriterReservation(name: $0.name, tokens: $0.tokens, cap: $0.cap, fromPlan: $0.fromPlan) })
  }
}

struct PinnedDisclosureSources: Codable, Equatable, Sendable {
  struct Fact: Codable, Equatable, Sendable {
    let factKey: String
    let text: String
    let constraintNote: String?
    let writerNote: String?
    let terms: [String]?
    let allowedClues: [String]?
    let subjects: [String]?
    let source: FactSource?
    let disclosedInChapter: Int?
    let revealChapter: Int?
    let unlock: UnlockCondition?
    let unlockUnreadable: Bool
  }

  struct Volume: Codable, Equatable, Sendable {
    let volumeKey: String
    let title: String?
    let objective: String?
    let body: String?
  }

  struct Page: Codable, Equatable, Sendable {
    let section: String
    let slug: String
    let body: String
  }

  let chapter: Int
  let lockedFacts: [Fact]
  let ending: String?
  let endingQuestion: String?
  let laterVolumes: [Volume]
  let plannerPages: [Page]
  let volumeOrdinals: [String: Int]
  let currentVolumeOrdinal: Int?

  init(_ sources: WriterDisclosureSources) {
    chapter = sources.chapter
    lockedFacts = sources.lockedFacts.map { fact in
      var condition: UnlockCondition?
      if case .condition(let held)? = fact.unlock { condition = held }
      return Fact(
        factKey: fact.factKey, text: fact.text, constraintNote: fact.constraintNote, writerNote: fact.writerNote, terms: fact.terms, allowedClues: fact.allowedClues,
        subjects: fact.subjects, source: fact.source, disclosedInChapter: fact.disclosedInChapter, revealChapter: fact.revealChapter, unlock: condition,
        unlockUnreadable: fact.unlock == .unreadable)
    }
    ending = sources.ending
    endingQuestion = sources.endingQuestion
    laterVolumes = sources.laterVolumes.map { Volume(volumeKey: $0.volumeKey, title: $0.title, objective: $0.objective, body: $0.body) }
    plannerPages = sources.plannerPages.map { Page(section: $0.address.section, slug: $0.address.slug, body: $0.body) }
    volumeOrdinals = Dictionary(uniqueKeysWithValues: sources.volumeOrdinals.map { ($0.key.value, $0.value) })
    currentVolumeOrdinal = sources.currentVolumeOrdinal
  }

  var sources: WriterDisclosureSources {
    WriterDisclosureSources(
      chapter: chapter,
      lockedFacts: lockedFacts.map { fact in
        DisclosureFact(
          factKey: fact.factKey, text: fact.text, constraintNote: fact.constraintNote, writerNote: fact.writerNote, terms: fact.terms, allowedClues: fact.allowedClues,
          subjects: fact.subjects, source: fact.source, disclosedInChapter: fact.disclosedInChapter, revealChapter: fact.revealChapter,
          unlock: fact.unlockUnreadable ? .unreadable : fact.unlock.map(FactUnlock.condition))
      }, ending: ending, endingQuestion: endingQuestion,
      laterVolumes: laterVolumes.map { LaterVolume(volumeKey: $0.volumeKey, title: $0.title, objective: $0.objective, body: $0.body) },
      plannerPages: plannerPages.map { DisclosurePage(address: BibleDocAddress(section: $0.section, slug: $0.slug), body: $0.body) },
      volumeOrdinals: Dictionary(uniqueKeysWithValues: volumeOrdinals.map { (JSString($0.key), $0.value) }), currentVolumeOrdinal: currentVolumeOrdinal)
  }
}

/// `nf_local_writer_pack`: one row per attempt this device runs and pack options it asked for, cleared with the attempt's local run so a settled attempt leaves no pack behind.
enum WriterPackPins {
  static let table = "nf_local_writer_pack"
  private static let definition = """
    CREATE TABLE IF NOT EXISTS nf_local_writer_pack (
      attempt BLOB NOT NULL, options BLOB NOT NULL, novel BLOB NOT NULL, pack BLOB NOT NULL, built_at INTEGER NOT NULL, PRIMARY KEY (attempt, options)
    ) STRICT, WITHOUT ROWID
    """

  /// Keeps the first pack an attempt pinned, so a step that raced another build of it reads the one already kept.
  static func pin(
    _ pack: PinnedWriterPack, options: WriterPackOptions, attempt: AttemptID, novel: UUID, at now: Date, in database: Database
  ) throws(StoreError) -> PinnedWriterPack {
    do {
      try database.execute(sql: definition)
      try database.execute(
        sql: "INSERT OR IGNORE INTO \(table) (attempt, options, novel, pack, built_at) VALUES (?, ?, ?, ?, ?)",
        arguments: [
          attempt.uuid, try encoded(PinnedOptions(options)), novel, try encoded(pack), Int64(exactly: (now.timeIntervalSince1970 * 1000).rounded(.down)) ?? 0,
        ])
      return try pinned(attempt, options: options, in: database) ?? pack
    } catch {
      throw StoreError(projecting: error)
    }
  }

  static func pinned(_ attempt: AttemptID, options: WriterPackOptions, in database: Database) throws(StoreError) -> PinnedWriterPack? {
    do {
      guard try database.tableExists(table),
        let bytes = try Data.fetchOne(
          database, sql: "SELECT pack FROM \(table) WHERE attempt = ? AND options = ?", arguments: [attempt.uuid, try encoded(PinnedOptions(options))])
      else { return nil }
      return try? JSONDecoder().decode(PinnedWriterPack.self, from: bytes)
    } catch {
      throw StoreError(projecting: error)
    }
  }

  /// Every pack whose attempt has no local run of `replica` any more: it settled, was forgotten, or was another replica's.
  @discardableResult
  static func forgetSettled(keeping replica: ReplicaID, in database: Database) throws(StoreError) -> Int {
    let kept = Set(try JobsLocal.runs(of: replica, in: database).map(\.attempt.uuid))
    do {
      guard try database.tableExists(table) else { return 0 }
      let attempts = Set(try UUID.fetchAll(database, sql: "SELECT attempt FROM \(table)")).subtracting(kept)
      for attempt in attempts { try database.execute(sql: "DELETE FROM \(table) WHERE attempt = ?", arguments: [attempt]) }
      return attempts.count
    } catch {
      throw StoreError(projecting: error)
    }
  }

  /// With its novel: a later step of an attempt still running rebuilds the pack from what is left.
  static func forget(novel: UUID, in database: Database) throws(StoreError) {
    do {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "DELETE FROM \(table) WHERE novel = ?", arguments: [novel])
    } catch {
      throw StoreError(projecting: error)
    }
  }

  private static func encoded<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(value)
  }
}

private struct PinnedOptions: Codable, Equatable {
  let budgetTokens: Int
  let permissive: Bool
  let minorNames: [String]
  let enforceReservations: Bool

  init(_ options: WriterPackOptions) {
    budgetTokens = options.budgetTokens
    permissive = options.permissive
    minorNames = options.minorNames
    enforceReservations = options.enforceReservations
  }
}
