import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore

nonisolated struct VersionEntry: Sendable, Equatable, Identifiable {
  let version: DraftVersion
  let title: String?
  let excerpt: String
  let words: Int

  var id: String { version.revision }
}

nonisolated struct ChapterVersions: ReadModel {
  enum State: Sendable, Equatable {
    case missing
    case final
    case listed([VersionEntry], kept: ChapterText?)
  }

  let state: State

  static func load(_ locator: ChapterLocator, in transaction: ReadTransaction) throws(StoreError) -> ChapterVersions {
    guard let ref = try? DraftRecord.ref(novel: locator.novel, chapter: locator.chapter) else { return ChapterVersions(state: .missing) }
    if let final = try? FinalChapterRecord.ref(novel: locator.novel, chapter: locator.chapter), case .readable(let entry) = try FinalChapterRecord.read(final, in: transaction),
      !entry.isRemoved
    {
      return ChapterVersions(state: .final)
    }
    let versions: [DraftVersion]
    do throws(DomainError) {
      versions = try DraftVersions.list(novel: locator.novel, chapter: locator.chapter, in: transaction)
    } catch {
      guard case .store(let failure) = error else { return ChapterVersions(state: .missing) }
      throw failure
    }
    let history = try DraftRecord.history(ref, in: transaction).history
    let bodies = Dictionary(uniqueKeysWithValues: (history?.revisions ?? []).map { ($0.id, $0.body.body) })
    let copy = try DraftWorkingCopy.read(novel: locator.novel, chapter: locator.chapter, in: transaction.database)
    let kept = copy.flatMap { $0.base == history?.head ? nil : ChapterText(title: $0.content.title ?? "", body: $0.content.body) }
    return ChapterVersions(state: .listed(versions.map { entry(for: $0, content: bodies[$0.revision] ?? nil) }, kept: kept))
  }

  private static func entry(for version: DraftVersion, content: DraftContent?) -> VersionEntry {
    guard let content else { return VersionEntry(version: version, title: nil, excerpt: "", words: 0) }
    let flat = content.body.split(whereSeparator: \.isWhitespace)
    return VersionEntry(version: version, title: content.title, excerpt: flat.prefix(40).joined(separator: " "), words: flat.count)
  }
}
