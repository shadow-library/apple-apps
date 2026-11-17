import Foundation
import NovelForgeCore
import ShadowStore

nonisolated struct ChapterOutline: ReadModel {
  let presence: NovelPresence
  let rows: Derived<[ChapterRow]>
  let next: Derived<Int>
  let volumes: Derived<[VolumeSummary]>
  let headings: Derived<[Int: String]>

  static func load(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChapterOutline {
    let presence = try presence(of: novel, in: transaction)
    guard case .present = presence else { return ChapterOutline(presence: presence, rows: .available([]), next: .available(1), volumes: .available([]), headings: .available([:])) }
    let list = try ChapterList.load(novel, in: transaction)
    let listed = Set(list.rows.value?.map(\.chapter) ?? [])
    let headings = try ChapterHeadings.load(novel, in: transaction).headings
    let shown = headings.value?.filter { listed.contains($0.key) } ?? [:]
    let structure = try StoryStructure.load(novel, in: transaction)
    let (titles, claims): (Derived<[Int: String]>, Derived<[Int: String]>) =
      switch headings {
      case .unavailable(let faults): (.unavailable(faults), .unavailable(faults))
      case .available: (.available(shown.compactMapValues(\.title)), .available(shown.compactMapValues(\.volume)))
      }
    return ChapterOutline(presence: presence, rows: list.rows, next: list.next, volumes: summaries(structure.volumes, claims: claims), headings: titles)
  }

  var groups: [ChapterGroup] {
    ChapterGrouping.group(volumes: volumes.value ?? [], chapters: rows.value?.map(\.chapter) ?? [])
  }

  var nextWritable: Int? {
    rows.value.map { Self.nextWritable(in: $0) }
  }

  static func nextWritable(in rows: [ChapterRow]) -> Int {
    ChapterSequence.nextWritable(
      draftChapters: rows.filter { $0.stage == .drafted || $0.stage == .approved }.map(\.chapter), finalizedChapters: rows.filter { $0.stage == .final }.map(\.chapter))
  }

  private static func presence(of novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> NovelPresence {
    switch try NovelRecord.read(id: novel, in: transaction) {
    case .absent: .missing
    case .unreadable: .unreadable
    case .readable(let entry): entry.isRemoved ? .missing : .present(entry.record)
    }
  }

  private static func summaries(_ volumes: Derived<StructureSection<VolumeItem>>, claims: Derived<[Int: String]>) -> Derived<[VolumeSummary]> {
    switch (volumes, claims) {
    case (.unavailable(let faults), _), (_, .unavailable(let faults)): return .unavailable(faults)
    case (.available(let section), .available(let claims)):
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

nonisolated enum ChapterListing: Equatable {
  case pending
  case unavailable
  case ready(nextWritable: Int)
}

nonisolated enum MissingChapter: Equatable {
  case pending
  case undetermined
  case unstarted
  case awaitingDraft
  case removed

  init(row: ChapterRow?, chapter: Int, listing: ChapterListing) {
    switch (row, listing) {
    case (.some, _): self = .awaitingDraft
    case (nil, .pending): self = .pending
    case (nil, .unavailable): self = .undetermined
    case (nil, .ready(let next)): self = next == chapter ? .unstarted : .removed
    }
  }
}
