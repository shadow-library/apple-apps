import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport

@testable import NovelForgeCore

/// Which chapter an operation aims at: most often one this device holds in the state the operation needs, sometimes one past the story cursor, otherwise any
/// number, so the guards refuse too.
struct ChapterAim: Sendable {
  enum Want: Sendable {
    case drafted
    case unapproved
    case stale
    case approved
    case final
    case open
  }

  enum Mode: Sendable {
    case state
    case pastCursor
    case any
  }

  let want: Want
  let pick: Int
  let any: Int
  let mode: Mode

  init(_ want: Want, _ generator: inout SeededGenerator, _ universe: DomainUniverse) {
    self.want = want
    pick = generator.int(in: 0...7)
    any = universe.chapter(&generator)
    mode = generator.chance(0.7) ? .state : generator.chance(0.5) ? .pastCursor : .any
  }

  func chapter(novel: UUID, in database: Database) throws -> Int {
    let cursor = try StoryCursor.filter(Column("novel") == novel).fetchOne(database)?.chapter ?? 1
    switch mode {
    case .any: return any
    case .pastCursor: return cursor + 1 + pick % 2
    case .state: break
    }
    let entries = try ChapterLifecycleEntry.filter(Column("novel") == novel).order(Column("chapter")).fetchAll(database).filter { !$0.isFinal || want == .final }
    let candidates: [Int] =
      switch want {
      case .drafted: entries.filter { $0.draft != nil }.map(\.chapter)
      case .unapproved: entries.filter { $0.review == .needsReview }.map(\.chapter)
      case .stale: entries.filter { $0.stale != nil }.map(\.chapter)
      case .approved: entries.filter { $0.review == .approved }.map(\.chapter)
      case .final: entries.filter(\.isFinal).map(\.chapter)
      case .open: [cursor, cursor + 1, cursor + 2]
      }
    return candidates.isEmpty ? any : candidates[pick % candidates.count]
  }
}

/// The chapter operations as the app calls them: plans, hand-written and imported drafts, versions, approval through `VaultStore.approveChapter`, finalize and the
/// final chapter's text; plus a device that writes the next chapter, teaching what its cast does not know yet, to a draft, an approval or final, and sometimes
/// drafts the one after, so runs reach later chapters and drafts that rest on unfinalized or contested ones.
enum DomainChapterOperations {
  static let all: [DomainOperation] = [
    DomainOperation(name: "write a plan", weight: 6) { generator, universe in
      let novel = universe.novel(&generator)
      let (aim, edit) = (ChapterAim(generator.chance(0.3) ? .approved : .open, &generator, universe), planEdit(&generator, universe))
      return .write { transaction, _ in try ChapterPlans.write(novel: novel, chapter: try aim.chapter(novel: novel, in: transaction.database), edit, in: &transaction) }
    },
    DomainOperation(name: "claim a milestone", weight: 3) { generator, universe in
      let (novel, aim, milestone) = (universe.primary, ChapterAim(.open, &generator, universe), universe.milestone(&generator))
      var edit = PlanEdit(body: universe.prose(&generator))
      edit.claimedMilestones = .set(generator.chance(0.85) ? [milestone] : [])
      let plan = edit
      return .write { transaction, _ in try ChapterPlans.write(novel: novel, chapter: try aim.chapter(novel: novel, in: transaction.database), plan, in: &transaction) }
    },
    DomainOperation(name: "plan an ending", weight: 4) { generator, universe in
      let (novel, aim, ends) = (universe.primary, ChapterAim(.open, &generator, universe), generator.chance(0.75))
      var edit = PlanEdit(body: universe.prose(&generator))
      edit.isEnding = .set(ends)
      let plan = edit
      return .write { transaction, _ in try ChapterPlans.write(novel: novel, chapter: try aim.chapter(novel: novel, in: transaction.database), plan, in: &transaction) }
    },
    DomainOperation(name: "save a hand-written draft", weight: 6) { generator, universe in
      let (novel, aim, body, againstHead) = (universe.novel(&generator), ChapterAim(.drafted, &generator, universe), universe.prose(&generator), generator.chance(0.85))
      let (summary, starts) = (generator.chance(0.8) ? "It turns." : nil, generator.chance(0.45))
      return .write { transaction, now in
        let chapter = starts ? try ChapterDrafts.nextWritableChapter(novel: novel, in: transaction) : try aim.chapter(novel: novel, in: transaction.database)
        let base = againstHead ? try head(novel: novel, chapter: chapter, in: transaction) : nil
        _ = try ChapterDrafts.save(novel: novel, chapter: chapter, DraftEdit(body: body, summary: summary), base: base, at: now, in: &transaction)
      }
    },
    DomainOperation(name: "import a draft", weight: 1) { generator, universe in
      let (novel, aim, prose) = (universe.novel(&generator), ChapterAim(.drafted, &generator, universe), universe.prose(&generator))
      return .write { transaction, _ in
        let chapter = try aim.chapter(novel: novel, in: transaction.database)
        let base = try head(novel: novel, chapter: chapter, in: transaction)
        _ = try ChapterDrafts.importDraft(novel: novel, chapter: chapter, DraftImport(prose: prose, summary: "Imported."), base: base, in: &transaction)
      }
    },
    DomainOperation(name: "start the next chapter", weight: 1) { generator, universe in
      let novel = universe.novel(&generator)
      return .write { transaction, _ in _ = try ChapterDrafts.startNext(novel: novel, in: &transaction) }
    },
    DomainOperation(name: "commit the working copy", weight: 2) { generator, universe in
      let (novel, aim) = (universe.novel(&generator), ChapterAim(.drafted, &generator, universe))
      return .write { transaction, _ in
        _ = try ChapterDrafts.commitWorkingCopy(novel: novel, chapter: try aim.chapter(novel: novel, in: transaction.database), in: &transaction)
      }
    },
    DomainOperation(name: "approve a draft", weight: 7) { generator, universe in
      let (novel, id, asWritten, current) = (universe.novel(&generator), generator.uuid(), generator.chance(0.5), generator.chance(0.9))
      let aim = ChapterAim(asWritten ? .stale : .unapproved, &generator, universe)
      return .store { store in
        let (chapter, revision, stale) = try await store.read { transaction in
          let chapter = try aim.chapter(novel: novel, in: transaction.database)
          return (
            chapter, try head(novel: novel, chapter: chapter, in: transaction),
            try ChapterLifecycleEntry.read(novel: novel, chapter: chapter, in: transaction.database)?.stale
          )
        }
        let intent: ApprovalIntent = asWritten ? .asWritten(seen: stale ?? .unrecorded) : .standard
        try await store.approveChapter(novel: novel, chapter: chapter, revision: current ? revision ?? "v:none" : "v:stale", as: intent, id: id)
      }
    },
    DomainOperation(name: "finalize a chapter", weight: 6) { generator, universe in
      let (novel, aim, lowest) = (universe.primary, ChapterAim(.approved, &generator, universe), generator.chance(0.3))
      return .write { transaction, _ in
        _ = try ChapterFinalize.finalize(novel: novel, chapter: lowest ? nil : try aim.chapter(novel: novel, in: transaction.database), in: &transaction)
      }
    },
    DomainOperation(name: "restore a draft version", weight: 1) { generator, universe in
      let (novel, aim, pick) = (universe.novel(&generator), ChapterAim(.drafted, &generator, universe), generator.int(in: 0...3))
      return .write { transaction, _ in
        let chapter = try aim.chapter(novel: novel, in: transaction.database)
        let versions = try DraftVersions.list(novel: novel, chapter: chapter, in: transaction)
        let revision = versions.isEmpty ? "v:none" : versions[pick % versions.count].revision
        let base = try head(novel: novel, chapter: chapter, in: transaction)
        _ = try DraftVersions.restore(novel: novel, chapter: chapter, revision: revision, base: base, in: &transaction)
      }
    },
    DomainOperation(name: "amend a final chapter or its summary", weight: 2) { generator, universe in
      let (novel, aim, text, summary) = (universe.novel(&generator), ChapterAim(.final, &generator, universe), universe.prose(&generator), generator.chance(0.4))
      return .write { transaction, _ in
        let chapter = try aim.chapter(novel: novel, in: transaction.database)
        if summary {
          try FinalChapters.editSummary(novel: novel, chapter: chapter, summary: text, in: &transaction)
        } else {
          try FinalChapters.amend(novel: novel, chapter: chapter, ChapterAmendment(content: text), in: &transaction)
        }
      }
    },
    DomainOperation(name: "write the next chapter to a draft, an approval or final, then maybe draft the one after", weight: 5) { generator, universe in
      let (novel, body, id, stage) = (universe.primary, universe.prose(&generator), generator.uuid(), generator.int(in: 0...4))
      let (pov, picks) = (universe.entity(&generator), (0...generator.int(in: 0...1)).map { _ in generator.int(in: 0...11) })
      let entities = universe.entities
      return .store { store in
        let chapter = try await store.read { transaction in try StoryCursor.filter(Column("novel") == novel).fetchOne(transaction.database)?.chapter ?? 1 }
        let draft = { (chapter: Int) async throws -> String in
          let unknown = try await store.read { transaction in
            let facts = try SecretRecord.listing(novel: novel, in: transaction).live.filter { $0.unlock == nil && $0.revealChapter.map { $0 <= chapter } == true }
            let known = Set(try CharacterKnowledgeDerivation.request(for: novel).fetchAll(transaction.database).map { "\($0.fact) \($0.entity)" })
            return facts.map(\.secret).sorted().flatMap { fact in entities.map { KnowledgeReveal(entityKey: $0, factKey: fact) } }.filter {
              !known.contains("\($0.factKey) \($0.entityKey)")
            }
          }
          var plan = PlanEdit(body: body)
          let learns = unknown.isEmpty ? [] : picks.map { unknown[$0 % unknown.count] }
          plan.knowledge = .set(PlanKnowledge(pov: [pov], learns: learns))
          let edit = plan
          try await store.writeDomain { transaction throws(DomainError) in try ChapterPlans.write(novel: novel, chapter: chapter, edit, in: &transaction) }
          let base = try await store.read { transaction in try head(novel: novel, chapter: chapter, in: transaction) }
          let now = store.wallClock()
          return try await store.writeDomain { transaction throws(DomainError) in
            try ChapterDrafts.save(novel: novel, chapter: chapter, DraftEdit(body: body, summary: "It turns."), base: base, at: now, in: &transaction).base
          }
        }
        let saved = try await draft(chapter)
        guard stage > 0 else { return }
        try await store.approveChapter(novel: novel, chapter: chapter, revision: saved, id: id)
        if stage == 3 { _ = try await draft(chapter + 1) }
        guard stage != 3 else { return }
        try await store.writeDomain { transaction throws(DomainError) in _ = try ChapterFinalize.finalize(novel: novel, chapter: chapter, in: &transaction) }
        if stage == 4 { _ = try await draft(chapter + 1) }
      }
    },
  ]

  static func head(novel: UUID, chapter: Int, in transaction: borrowing some StateReading & ~Copyable) throws -> String? {
    guard case .revisioned(let state)? = try transaction.state(of: try DraftRecord.ref(novel: novel, chapter: chapter), scope: .vault), !state.revisions.isEmpty else {
      return nil
    }
    return state.headRevision
  }

  private static func planEdit(_ generator: inout SeededGenerator, _ universe: DomainUniverse) -> PlanEdit {
    var edit = PlanEdit(body: universe.prose(&generator))
    if generator.chance(0.8) { edit.knowledge = .set(PlanKnowledge(pov: generator.chance(0.9) ? [universe.entity(&generator)] : [], learns: universe.learns(&generator))) }
    if let claims = universe.claims(&generator) { edit.claimedMilestones = .set(claims) }
    if generator.chance(0.2) { edit.isEnding = .set(generator.chance(0.7)) }
    return edit
  }
}
