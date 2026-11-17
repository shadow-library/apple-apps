import Foundation
import ShadowStore

@testable import NovelForgeCore

/// Every read model of a novel loads with nothing unavailable and no fault, and shows what the records and the checked derived rows say.
enum DomainReadModelChecks {
  struct Expected {
    let frontier: Int
    let finals: Set<Int>
    let approvals: [Int: UUID]
    let lifecycle: Set<Int>
    let activeVolume: String?
    let milestones: Int
    let duplicates: [String: [Int]]
    let volumes: [String: VolumeState]
    let secrets: Int
    let promises: Int
    let pages: Int
    let entities: Int
    let notebook: [LedgerEntryStatus: Int]
    let shownEntries: Int
    let knowledge: Set<CharacterKnowledgeEntry>
  }

  static func check(_ novel: UUID, expecting expected: Expected, in transaction: ReadTransaction) throws -> [String] {
    var found = [String]()
    func expect(_ holds: Bool, _ rule: String) { if !holds { found.append("read model: \(rule)") } }
    func available<Value>(_ derived: Derived<Value>, _ name: String) -> Value? {
      expect(!derived.isUnavailable, "\(name) is available")
      return derived.value
    }

    let chapters = try ChapterList.load(novel, in: transaction)
    expect(chapters.faults.isEmpty, "the chapter list reports no fault")
    if let rows = available(chapters.rows, "the chapter list") {
      expect(Set(rows.map(\.chapter)) == expected.lifecycle, "the chapter list has a row per chapter of the lifecycle")
      expect(Set(rows.filter { $0.stage == .final }.map(\.chapter)) == expected.finals, "the chapter list shows exactly the final chapters final")
      expect(rows.allSatisfy { $0.approval == expected.approvals[$0.chapter] }, "the chapter list shows the approval in force")
      expect(rows.allSatisfy { ($0.stage == .approved) == (expected.approvals[$0.chapter] != nil) }, "the chapter list shows a chapter approved iff an approval is in force")
    }
    expect(available(chapters.next, "the next chapter") == expected.frontier + 1, "the chapter list's next chapter is the story cursor")
    _ = available(chapters.reveals, "the reveal verdicts")

    let overview = try NovelOverview.load(novel, in: transaction)
    expect(overview.faults.isEmpty, "the overview reports no fault")
    if let tally = available(overview.chapters, "the chapter tally") {
      expect(tally.finals == expected.finals.count && tally.next == expected.frontier + 1, "the chapter tally counts the finals and names the cursor")
      expect(tally.approved == expected.approvals.count, "the chapter tally counts the approvals in force")
    }
    if let active = available(overview.activeVolume, "the active volume") { expect(active?.volume == expected.activeVolume, "the overview names the active volume") }
    if let milestones = available(overview.milestones, "the milestone tally") {
      expect(milestones.open + milestones.planned + milestones.reached == expected.milestones, "the milestone tally counts the live milestones")
    }
    expect(available(overview.notebookEntries, "the Notebook count") == expected.shownEntries, "the overview counts the active Notebook entries shown")
    if let bible = available(overview.bible, "the Bible tally") {
      expect(bible.pages == expected.pages && bible.entities == expected.entities, "the Bible tally counts the live pages and entities")
    }

    let structure = try StoryStructure.load(novel, in: transaction)
    expect(structure.faults.isEmpty, "the story structure reports no fault")
    if let volumes = available(structure.volumes, "the volumes") {
      expect(Dictionary(uniqueKeysWithValues: volumes.items.map { ($0.record.volume, $0.state) }) == expected.volumes, "the story structure shows each volume's state")
    }
    if let milestones = available(structure.milestones, "the milestones") {
      expect(milestones.items.count == expected.milestones, "the story structure lists the live milestones")
      expect(milestones.items.allSatisfy { $0.duplicateClaims == (expected.duplicates[$0.record.milestone] ?? []) }, "the story structure flags duplicate claims")
    }
    expect(available(structure.promises, "the promises")?.items.count == expected.promises, "the story structure lists the live promises")
    expect(available(structure.secrets, "the secrets")?.items.count == expected.secrets, "the story structure lists the live secrets")

    let bible = try StoryBibleContents.load(novel, in: transaction)
    expect(bible.faults.isEmpty, "the Story Bible reports no fault")
    expect(available(bible.pages, "the pages")?.items.count == expected.pages, "the Story Bible lists the live pages")
    expect(available(bible.entities, "the entities")?.items.count == expected.entities, "the Story Bible lists the live entities")

    let notebook = try NotebookContents.load(NotebookQuery(novel: novel), in: transaction)
    expect(notebook.faults.isEmpty, "the Notebook reports no fault")
    if let contents = available(notebook.notebook, "the Notebook") {
      let counts = [LedgerEntryStatus.active: contents.counts.active, .superseded: contents.counts.superseded, .withdrawn: contents.counts.withdrawn].filter { $0.value > 0 }
      expect(counts == expected.notebook, "the Notebook counts each status")
      expect(contents.entries.count == expected.shownEntries, "the Notebook shows the active entries")
    }

    let ledger = try KnowledgeLedger.load(novel, in: transaction)
    expect(ledger.faults.isEmpty, "the knowledge ledger reports no fault")
    expect(available(ledger.entries, "the knowledge ledger").map(Set.init) == expected.knowledge, "the knowledge ledger shows the derived knowledge")
    return found
  }

  static func checkLibrary(in transaction: ReadTransaction, into found: inout [String]) throws {
    let library = try LibraryList.load((), in: transaction)
    let live = try NovelRecord.listing(in: transaction).live
    if !library.faults.isEmpty { found.append("read model: the library reports no fault") }
    if library.novels.contains(where: { $0.chapters.isUnavailable }) || library.archived.contains(where: { $0.chapters.isUnavailable }) {
      found.append("read model: every library entry's chapter tally is available")
    }
    if Set(library.novels.map(\.novel.id)) != Set(live.filter { !$0.archived }.map(\.id)) || Set(library.archived.map(\.novel.id)) != Set(live.filter(\.archived).map(\.id)) {
      found.append("read model: the library lists the live novels by archive state")
    }
  }
}
