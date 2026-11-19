import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore

nonisolated struct VersionTag: Sendable, Equatable, Hashable {
  let run: String?
  let job: EntityKey?

  var key: String? { job?.rawValue ?? run }
}

nonisolated struct GenerationVersions: ReadModel {
  let versions: ChapterVersions
  let tags: [String: VersionTag]
  let judged: Set<String>
  let generating: Bool

  func canRestore(_ entry: VersionEntry) -> Bool { !generating && !entry.version.isCurrent }

  static func load(_ locator: ChapterLocator, in transaction: ReadTransaction) throws(StoreError) -> GenerationVersions {
    let versions = try ChapterVersions.load(locator, in: transaction)
    let generating = (try? ChapterList.load(locator.novel, in: transaction).rows.value?.first { $0.chapter == locator.chapter }?.review == .generating) ?? false
    guard case .listed = versions.state, let ref = try? DraftRecord.ref(novel: locator.novel, chapter: locator.chapter) else {
      return GenerationVersions(versions: versions, tags: [:], judged: [], generating: generating)
    }
    let history = (try? DraftRecord.history(ref, in: transaction))?.history
    let tags = Dictionary(
      (history?.revisions ?? []).compactMap { revision -> (String, VersionTag)? in
        guard let content = revision.body.body, content.run != nil || content.job != nil else { return nil }
        return (revision.id, VersionTag(run: content.run, job: content.job))
      }, uniquingKeysWith: { first, _ in first })
    let reviews = (try? ChapterReviewRecord.listing(novel: locator.novel, chapter: locator.chapter, in: transaction).entries.map(\.record)) ?? []
    let judged = Set(reviews.filter(\.generationPass).compactMap(\.draftRevision))
    return GenerationVersions(versions: versions, tags: tags, judged: judged, generating: generating)
  }
}

nonisolated struct VersionGroup: Sendable, Equatable, Identifiable {
  enum Kind: Sendable, Equatable {
    case run(Int)
    case other
  }

  let id: String
  let kind: Kind
  let entries: [VersionEntry]
}

nonisolated enum VersionGrouping {
  /// Entries newest first. A run's saves share its job (else its run) tag and sit together at the run's newest save; the untagged ones between stay in order.
  static func group(_ entries: [VersionEntry], tags: [String: VersionTag]) -> [VersionGroup] {
    let byRevision = Dictionary(entries.map { ($0.version.revision, $0) }, uniquingKeysWith: { first, _ in first })
    var number = order(entries.map(\.version.revision), tags: tags).filter { $0.key != nil }.count
    return order(entries.map(\.version.revision), tags: tags).enumerated().map { offset, bucket in
      let members = bucket.revisions.compactMap { byRevision[$0] }
      guard let key = bucket.key else { return VersionGroup(id: "other-\(offset)", kind: .other, entries: members) }
      defer { number -= 1 }
      return VersionGroup(id: "run-\(key)", kind: .run(number), entries: members)
    }
  }

  static func order(_ revisions: [String], tags: [String: VersionTag]) -> [(key: String?, revisions: [String])] {
    var buckets: [(key: String?, revisions: [String])] = []
    for revision in revisions {
      let key = tags[revision]?.key
      if let key, let index = buckets.firstIndex(where: { $0.key == key }) {
        buckets[index].revisions.append(revision)
      } else if key == nil, let last = buckets.last, last.key == nil {
        buckets[buckets.count - 1].revisions.append(revision)
      } else {
        buckets.append((key, [revision]))
      }
    }
    return buckets
  }
}

nonisolated struct VersionTexts: Sendable, Equatable {
  let older: String
  let newer: String
}

nonisolated enum VersionTextsError: Error, Sendable, Equatable {
  case unreadable(String)
}

extension VaultStore {
  func versionTexts(novel: UUID, chapter: Int, older: String, newer: String) async throws -> VersionTexts {
    try await read { transaction in
      let ref = try DraftRecord.ref(novel: novel, chapter: chapter)
      let revisions = try DraftRecord.history(ref, in: transaction).history?.revisions ?? []
      func body(_ id: String) throws -> String {
        guard let content = revisions.first(where: { $0.id == id })?.body.body else { throw VersionTextsError.unreadable(id) }
        return content.body
      }
      return VersionTexts(older: try body(older), newer: try body(newer))
    }
  }
}
