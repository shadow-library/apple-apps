import Foundation
import NovelForgeCore
import ShadowStore

nonisolated struct ChapterOutline: ReadModel {
  let presence: NovelPresence
  let rows: Derived<[ChapterRow]>
  let next: Derived<Int>
  let volumes: Derived<[VolumeSummary]>
  let headings: [Int: String]

  static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChapterOutline {
    let presence = try presence(of: novel, in: transaction)
    guard case .present = presence else { return ChapterOutline(presence: presence, rows: .available([]), next: .available(1), volumes: .available([]), headings: [:]) }
    let list = try ChapterList.load(novel, in: transaction)
    let facts = list.rows.isUnavailable ? ChapterFacts() : try ChapterFacts.load(novel: novel, chapters: list.rows.value?.map(\.chapter) ?? [], in: transaction)
    let structure = try StoryStructure.load(novel, in: transaction)
    return ChapterOutline(presence: presence, rows: list.rows, next: list.next, volumes: summaries(structure.volumes, claims: facts.volumes), headings: facts.headings)
  }

  var groups: [ChapterGroup] {
    ChapterGrouping.group(volumes: volumes.value ?? [], chapters: rows.value?.map(\.chapter) ?? [])
  }

  var nextWritable: Int? {
    guard let rows = rows.value else { return nil }
    return ChapterSequence.nextWritable(
      draftChapters: rows.filter { $0.stage == .drafted || $0.stage == .approved }.map(\.chapter), finalizedChapters: rows.filter { $0.stage == .final }.map(\.chapter))
  }

  private static func presence(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> NovelPresence {
    switch try NovelRecord.read(id: novel, in: transaction) {
    case .absent: .missing
    case .unreadable: .unreadable
    case .readable(let entry): entry.isRemoved ? .missing : .present(entry.record)
    }
  }

  private static func summaries(_ volumes: Derived<StructureSection<VolumeItem>>, claims: [Int: String]) -> Derived<[VolumeSummary]> {
    switch volumes {
    case .unavailable(let faults): return .unavailable(faults)
    case .available(let section):
      return .available(
        section.items.map { item in
          let claimed = claims.filter { $0.value == item.record.volume }.keys
          return VolumeSummary(
            key: item.record.volume, ordinal: item.record.ordinal, title: item.record.title, objective: item.record.objective, state: item.state, planFirst: claimed.min(),
            planLast: claimed.max())
        })
    }
  }
}

nonisolated struct ChapterFacts {
  var headings: [Int: String] = [:]
  var volumes: [Int: String] = [:]

  static func load(novel: UUID, chapters: [Int], in transaction: ReadTransaction) throws(StoreError) -> ChapterFacts {
    var facts = ChapterFacts()
    for chapter in chapters {
      var title: String?
      var volume: String?
      if let ref = try? FinalChapterRecord.ref(novel: novel, chapter: chapter), case .readable(let entry) = try FinalChapterRecord.read(ref, in: transaction), !entry.isRemoved {
        title = entry.record.text.title
        volume = entry.record.canon.volume
      }
      if title == nil, let ref = try? DraftRecord.ref(novel: novel, chapter: chapter), case .readable(let entry) = try DraftRecord.readHead(ref, in: transaction), !entry.isRemoved
      {
        title = entry.record.content.title
      }
      if title == nil || volume == nil, let ref = try? ChapterPlanRecord.ref(novel: novel, chapter: chapter),
        case .readable(let entry) = try ChapterPlanRecord.readHead(ref, in: transaction),
        !entry.isRemoved
      {
        title = title ?? entry.record.content.title
        volume = volume ?? entry.record.content.volume
      }
      facts.headings[chapter] = title
      facts.volumes[chapter] = volume
    }
    return facts
  }
}
