import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport

@testable import NovelForgeCore

/// The app's write API for the library, the story, the Story Bible and the Notebook, called as the screens call it, with inputs that the guards sometimes refuse.
enum DomainOperations {
  static let library: [DomainOperation] = [
    DomainOperation(name: "create a novel", weight: 1) { generator, universe in
      let (novel, title, notes) = (universe.novel(&generator), universe.text(&generator), generator.chance(0.5) ? "Notes." : nil)
      return .write { transaction, _ in try Library.create(NewNovel(title: title, notes: notes), id: novel, in: &transaction) }
    },
    DomainOperation(name: "edit a novel", weight: 1) { generator, universe in
      let novel = universe.novel(&generator)
      var changes = NovelChanges()
      if generator.chance(0.6) { changes.title = .set(universe.text(&generator)) }
      if generator.chance(0.4) {
        let floor = generator.int(in: 400...3000)
        changes.wordTarget = .set(WordTarget(min: floor, max: floor + generator.int(in: -200...2000)))
      }
      if generator.chance(0.3) { changes.theme = .set(universe.text(&generator)) }
      let edit = changes
      return .write { transaction, _ in try Library.edit(novel: novel, edit, in: &transaction) }
    },
    DomainOperation(name: "archive or restore a novel", weight: 1) { generator, universe in
      let (novel, archives) = (universe.novel(&generator), generator.chance(0.5))
      return .write { transaction, _ in
        if archives { try Library.archive(novel: novel, in: &transaction) } else { try Library.restore(novel: novel, in: &transaction) }
      }
    },
    DomainOperation(name: "replace the author's notes", weight: 1) { generator, universe in
      let (novel, text) = (universe.novel(&generator), universe.text(&generator))
      return .write { transaction, _ in try Library.replaceNotes(novel: novel, text: text, in: &transaction) }
    },
    DomainOperation(name: "clone a novel", weight: 1) { generator, universe in
      let (source, copy, name) = (universe.novel(&generator), generator.uuid(), universe.text(&generator))
      return .write { transaction, _ in _ = try Library.clone(novel: source, as: NovelCopy(name: name), id: copy, in: &transaction) }
    },
  ]

  static let story: [DomainOperation] = [
    DomainOperation(name: "create a volume", weight: 2) { generator, universe in
      let (novel, volume, ordinal) = (universe.novel(&generator), universe.volume(&generator), generator.pick(from: [nil, 0, 1, 1, 2]))
      return .write { transaction, _ in try Volumes.create(novel: novel, volume: volume, ordinal: ordinal, in: &transaction) }
    },
    DomainOperation(name: "reorder a volume", weight: 3) { generator, universe in
      let (novel, fallback, pick, ordinal) = (universe.novel(&generator), universe.volume(&generator), generator.int(in: 0...7), generator.int(in: 0...2))
      return .write { transaction, _ in
        let live = try VolumeRecord.listing(novel: novel, in: transaction).live.map(\.volume)
        let volume = live.isEmpty || pick == 0 ? fallback : live[pick % live.count]
        try Volumes.edit(novel: novel, volume: volume, VolumeChanges(ordinal: .set(ordinal)), in: &transaction)
      }
    },
    DomainOperation(name: "remove or restore a volume", weight: 2) { generator, universe in
      let (novel, volume, toggle) = (universe.novel(&generator), universe.volume(&generator), Toggle(&generator))
      return .write { transaction, _ in
        if try toggle.removes(VolumeRecord.self, VolumeRecord.ref(novel: novel, volume: volume), in: transaction) {
          try Volumes.remove(novel: novel, volume: volume, in: &transaction)
        } else {
          try Volumes.restore(novel: novel, volume: volume, in: &transaction)
        }
      }
    },
    DomainOperation(name: "mark a volume's goal met", weight: 2) { generator, universe in
      let (novel, volume) = (universe.novel(&generator), universe.volume(&generator))
      return .write { transaction, _ in _ = try Volumes.markGoalMet(novel: novel, volume: volume, in: &transaction) }
    },
    DomainOperation(name: "create or relabel a milestone", weight: 2) { generator, universe in
      let (novel, milestone, label, creates) = (universe.novel(&generator), universe.milestone(&generator), universe.text(&generator), generator.chance(0.6))
      return .write { transaction, _ in
        if creates {
          try Milestones.create(novel: novel, milestone: milestone, label: label, in: &transaction)
        } else {
          try Milestones.edit(novel: novel, milestone: milestone, MilestoneChanges(label: label), in: &transaction)
        }
      }
    },
    DomainOperation(name: "remove or restore a milestone", weight: 2) { generator, universe in
      let (novel, milestone, toggle) = (universe.novel(&generator), universe.milestone(&generator), Toggle(&generator))
      return .write { transaction, _ in
        if try toggle.removes(MilestoneRecord.self, MilestoneRecord.ref(novel: novel, milestone: milestone), in: transaction) {
          try Milestones.remove(novel: novel, milestone: milestone, in: &transaction)
        } else {
          try Milestones.restore(novel: novel, milestone: milestone, in: &transaction)
        }
      }
    },
    DomainOperation(name: "create a promise", weight: 2) { generator, universe in
      let (novel, promise, label) = (universe.novel(&generator), universe.promise(&generator), universe.prose(&generator))
      return .write { transaction, _ in try Promises.create(novel: novel, promise, label: label, in: &transaction) }
    },
    DomainOperation(name: "settle a promise", weight: 2) { generator, universe in
      let (novel, aim, how, milestone) = (universe.novel(&generator), PromiseAim(&generator, universe), generator.int(in: 0...3), universe.milestone(&generator))
      return .write { transaction, _ in
        let promise = try aim.promise(novel: novel, liveOnly: true, in: transaction)
        switch how {
        case 0: try Promises.update(novel: novel, promise, settlement: .payOff, in: &transaction)
        case 1: try Promises.update(novel: novel, promise, settlement: .reopen, in: &transaction)
        case 2: try Promises.setPayoff(novel: novel, promise, .target(milestone: .set(milestone)), in: &transaction)
        default: try Promises.drop(novel: novel, promise, in: &transaction)
        }
      }
    },
    DomainOperation(name: "remove or restore a promise", weight: 1) { generator, universe in
      let (novel, aim, toggle) = (universe.novel(&generator), PromiseAim(&generator, universe), Toggle(&generator))
      return .write { transaction, _ in
        let promise = try aim.promise(novel: novel, liveOnly: false, in: transaction)
        if try toggle.removes(promise, novel: novel, in: transaction) {
          try Promises.remove(novel: novel, promise, in: &transaction)
        } else {
          try Promises.restore(novel: novel, promise, in: &transaction)
        }
      }
    },
    DomainOperation(name: "write a secret", weight: 4) { generator, universe in
      let (novel, secret, text) = (universe.novel(&generator), universe.secret(&generator), universe.text(&generator))
      var changes = SecretChanges()
      switch generator.int(in: 0...4) {
      case 0, 4: changes.revealChapter = .set(generator.int(in: 0...4))
      case 1: changes.unlock = .set(.object(["all": .array([.object(["milestone": .string(universe.milestone(&generator))])])]))
      case 2: changes.unlock = .set(nil)
      default: break
      }
      let edit = changes
      return .write { transaction, _ in try Secrets.upsert(novel: novel, secret: secret, text: text, edit, in: &transaction) }
    },
    DomainOperation(name: "remove or restore a secret", weight: 2) { generator, universe in
      let (novel, secret, toggle) = (universe.novel(&generator), universe.secret(&generator), Toggle(&generator))
      return .write { transaction, _ in
        if try toggle.removes(SecretRecord.self, SecretRecord.ref(novel: novel, secret: secret), in: transaction) {
          try Secrets.remove(novel: novel, secret: secret, in: &transaction)
        } else {
          try Secrets.restore(novel: novel, secret: secret, in: &transaction)
        }
      }
    },
    DomainOperation(name: "reveal or retract a fact for a character", weight: 2) { generator, universe in
      let (novel, secret, entity, chapter, reveals) = (
        universe.novel(&generator), universe.secret(&generator), universe.entity(&generator), generator.int(in: 0...4), generator.chance(0.6)
      )
      return .write { transaction, _ in
        if reveals {
          try ManualReveals.reveal(novel: novel, secret: secret, entity: entity, chapter: chapter, in: &transaction)
        } else {
          try ManualReveals.retract(novel: novel, secret: secret, entity: entity, in: &transaction)
        }
      }
    },
  ]

  static let bible: [DomainOperation] = [
    DomainOperation(name: "create or edit an entity", weight: 2) { generator, universe in
      let (novel, entity, name, creates) = (universe.novel(&generator), universe.entity(&generator), universe.text(&generator), generator.chance(0.5))
      let details = EntityDetails(status: generator.chance(0.5) ? universe.text(&generator) : nil, notes: generator.chance(0.5) ? "Seen." : nil)
      return .write { transaction, _ in
        if creates {
          try Entities.create(novel: novel, entity: entity, type: .character, name: name, details, in: &transaction)
        } else {
          try Entities.edit(novel: novel, entity: entity, name: name, details, in: &transaction)
        }
      }
    },
    DomainOperation(name: "remove or restore an entity", weight: 2) { generator, universe in
      let (novel, entity, toggle) = (universe.novel(&generator), universe.entity(&generator), Toggle(&generator))
      return .write { transaction, _ in
        if try toggle.removes(EntityRecord.self, EntityRecord.ref(novel: novel, entity: entity), in: transaction) {
          try Entities.remove(novel: novel, entity: entity, in: &transaction)
        } else {
          try Entities.restore(novel: novel, entity: entity, in: &transaction)
        }
      }
    },
    DomainOperation(name: "save a page", weight: 3) { generator, universe in
      let (novel, page, body, how) = (universe.novel(&generator), universe.page(&generator), universe.prose(&generator), generator.int(in: 0...2))
      return .write { transaction, _ in
        switch how {
        case 0: _ = try Pages.create(novel: novel, section: page.section, slug: page.slug, body: body, in: &transaction)
        case 1: _ = try Pages.revise(novel: novel, section: page.section, slug: page.slug, body: body, in: &transaction)
        default: _ = try Pages.save(novel: novel, section: page.section, slug: page.slug, body: body, in: &transaction)
        }
      }
    },
    DomainOperation(name: "remove or restore a page", weight: 1) { generator, universe in
      let (novel, page, toggle) = (universe.novel(&generator), universe.page(&generator), Toggle(&generator))
      return .write { transaction, _ in
        if try toggle.removes(PageRecord.self, PageRecord.ref(novel: novel, section: page.section, slug: page.slug), in: transaction) {
          try Pages.remove(novel: novel, section: page.section, slug: page.slug, in: &transaction)
        } else {
          try Pages.restore(novel: novel, section: page.section, slug: page.slug, in: &transaction)
        }
      }
    },
    DomainOperation(name: "restore a page version", weight: 1) { generator, universe in
      let (novel, page, pick) = (universe.novel(&generator), universe.page(&generator), generator.int(in: 0...3))
      return .write { transaction, _ in
        let versions = try Pages.versions(novel: novel, section: page.section, slug: page.slug, in: transaction)
        let revision = versions.isEmpty ? "v:none" : versions[pick % versions.count].revision
        _ = try Pages.restoreVersion(novel: novel, section: page.section, slug: page.slug, revision: revision, in: &transaction)
      }
    },
  ]

  static let notebook: [DomainOperation] = [
    DomainOperation(name: "record a Notebook entry by the author", weight: 2) { generator, universe in
      let (novel, kind, topic, statement) = (
        universe.novel(&generator), generator.pick(from: [LedgerEntryKind.direction, .rejected, .backlog, .direction, .decision]), generator.pick(from: universe.topics),
        generator.chance(0.9) ? universe.prose(&generator) : "  "
      )
      return .write { transaction, _ in
        _ = try Notebook.recordByAuthor(AuthorNotebookEntry(kind: kind, topic: topic, statement: statement), novel: novel, in: &transaction)
      }
    },
    DomainOperation(name: "record a Notebook rejection", weight: 1) { generator, universe in
      let (novel, idea, statement) = (universe.novel(&generator), generator.pick(from: ["moon", "storm"]), universe.text(&generator))
      let entry = NewNotebookEntry(
        kind: .rejected, topic: NotebookTopics.idea(idea), statement: statement, decidedBy: .author, idea: NotebookIdeaRejection(ideaId: idea, scope: .never))
      return .write { transaction, _ in _ = try Notebook.record(entry, novel: novel, in: &transaction) }
    },
    DomainOperation(name: "supersede a Notebook entry", weight: 3) { generator, universe in
      let (novel, pick, statement, byAuthor) = (universe.novel(&generator), generator.int(in: 0...15), universe.text(&generator), generator.chance(0.5))
      return .write { transaction, _ in
        let id = try entry(pick, novel: novel, in: transaction)
        if byAuthor {
          _ = try Notebook.supersedeByAuthor(id, rewrite: NotebookRewrite(statement: statement), novel: novel, in: &transaction)
        } else {
          _ = try Notebook.supersede(id, with: NotebookSuccessor(kind: .decision, decidedBy: .author, statement: statement), novel: novel, in: &transaction)
        }
      }
    },
    DomainOperation(name: "withdraw a Notebook entry", weight: 3) { generator, universe in
      let (novel, pick, reason) = (universe.novel(&generator), generator.int(in: 0...15), generator.chance(0.9) ? universe.prose(&generator) : "  ")
      return .write { transaction, _ in _ = try Notebook.withdraw(try entry(pick, novel: novel, in: transaction), reason: reason, novel: novel, in: &transaction) }
    },
  ]

  /// The `pick`th entry this device holds: mostly one of its two oldest active ones, so devices often retire the same entry, otherwise any, so that retiring a
  /// retired entry is tried too.
  private static func entry(_ pick: Int, novel: UUID, in transaction: borrowing WriteTransaction) throws -> UUID {
    let ledger = try NotebookLedger.load(novel: novel, in: transaction)
    let entries = pick % 4 == 0 ? ledger.entries : Array(ledger.active().prefix(2))
    guard !entries.isEmpty else { return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)) }
    return entries[pick % entries.count].id
  }
}

/// Removes a live record or restores a removed one, as the screen offers; now and then the other way round, so the guards refuse.
struct Toggle: Sendable {
  let guess: Bool
  let follows: Bool

  init(_ generator: inout SeededGenerator) {
    guess = generator.chance(0.5)
    follows = generator.chance(0.8)
  }

  func removes<Record: NovelForgeRecord>(_: Record.Type, _ ref: EntityRef, in transaction: borrowing WriteTransaction) throws -> Bool {
    guard follows else { return guess }
    guard case .readable(let entry) = try Record.read(ref, in: transaction) else { return false }
    return !entry.isRemoved
  }

  func removes(_ promise: PromiseRef, novel: UUID, in transaction: borrowing WriteTransaction) throws -> Bool {
    switch promise {
    case .thread(let key): try removes(ThreadRecord.self, ThreadRecord.ref(novel: novel, thread: key), in: transaction)
    case .mystery(let key): try removes(MysteryRecord.self, MysteryRecord.ref(novel: novel, mystery: key), in: transaction)
    }
  }
}

/// A promise this device holds (live, or live or removed), most of the time; otherwise any key, so the guards refuse too.
struct PromiseAim: Sendable {
  let fallback: PromiseRef
  let pick: Int

  init(_ generator: inout SeededGenerator, _ universe: DomainUniverse) {
    fallback = universe.promise(&generator)
    pick = generator.int(in: 0...7)
  }

  func promise(novel: UUID, liveOnly: Bool, in transaction: borrowing WriteTransaction) throws -> PromiseRef {
    let threads = try ThreadRecord.listing(novel: novel, in: transaction).entries.filter { !liveOnly || !$0.isRemoved }.map { PromiseRef.thread($0.record.thread) }
    let mysteries = try MysteryRecord.listing(novel: novel, in: transaction).entries.filter { !liveOnly || !$0.isRemoved }.map { PromiseRef.mystery($0.record.mystery) }
    let held = threads + mysteries
    return held.isEmpty || pick == 0 ? fallback : held[pick % held.count]
  }
}
