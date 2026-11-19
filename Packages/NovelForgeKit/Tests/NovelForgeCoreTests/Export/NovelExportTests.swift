import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private struct ExportFixture: Decodable {
  struct Novel: Decodable {
    let id: UUID
    let name: String
    let title: String?
    let brief: String?
    let premise: String?
    let themes: [String]?
  }

  struct Amendment: Decodable {
    let title: String?
    let content: String
  }

  struct Final: Decodable {
    let number: Int
    let title: String?
    let content: String
    let amendment: Amendment?
  }

  struct Draft: Decodable {
    let chapter: Int
    let title: String?
    let body: String
    let status: String
  }

  struct File: Decodable {
    let name: String
    let text: String
  }

  struct Package: Decodable {
    let error: String?
    let id: String?
    let filename: String?
    let chapterCount: Int?
    let manifest: String?
    let files: [File]?
  }

  struct Expected: Decodable {
    let manuscript: String
    let package: Package
  }

  struct Case: Decodable {
    let name: String
    let novel: Novel
    let finals: [Final]
    let drafts: [Draft]
    let expected: Expected
  }

  let cases: [Case]
}

@Suite("Novel export", TestTimeLimit.standard)
struct NovelExportTests {
  private let cases = (try? ReferenceFixture.decode(ExportFixture.self, from: "export/export.json").cases) ?? []

  @Test func shouldLoadTheReferenceCases() {
    #expect(cases.count == 6)
  }

  @Test func shouldMatchTheReferenceManuscriptAndPackage() async throws {
    for entry in cases {
      let store = try Projection.store(try Projection.reconciler())
      try await seed(entry, in: store)
      let manuscript = try await store.exportManuscript(novel: entry.novel.id)
      #expect(manuscript == entry.expected.manuscript, "\(entry.name): manuscript")

      let expected = entry.expected.package
      if let code = expected.error {
        do {
          _ = try await store.exportPackage(novel: entry.novel.id)
          Issue.record("\(entry.name): the package should be refused with \(code)")
        } catch {
          #expect(error.code == code, "\(entry.name): error")
        }
        continue
      }

      let package = try await store.exportPackage(novel: entry.novel.id)
      #expect(package.id == expected.id, "\(entry.name): id")
      #expect(package.filename == expected.filename, "\(entry.name): filename")
      #expect(package.chapterCount == expected.chapterCount, "\(entry.name): chapter count")
      #expect(package.manifest == expected.manifest, "\(entry.name): manifest")
      let archive = try ZipReading.entries(package.bytes)
      #expect(archive.map(\.name) == expected.files?.map(\.name), "\(entry.name): file names and order")
      #expect(archive.map { String(decoding: $0.data, as: UTF8.self) } == expected.files?.map(\.text), "\(entry.name): file bytes")
      #expect(package.files == archive.map(\.name))
    }
  }

  @Test func shouldWriteTheSamePackageBytesEachTime() async throws {
    let entry = try #require(cases.first { $0.name == "many chapters" })
    let store = try Projection.store(try Projection.reconciler())
    try await seed(entry, in: store)
    let first = try await store.exportPackage(novel: entry.novel.id)
    let second = try await store.exportPackage(novel: entry.novel.id)
    #expect(first.bytes == second.bytes)
    #expect(first.chapterCount == 122)
  }

  @Test func shouldRefuseANovelThatDoesNotExist() async throws {
    let store = try Projection.store(try Projection.reconciler())
    let missing = UUID()
    await #expect(throws: ExportError.novelNotFound(missing)) { try await store.exportPackage(novel: missing) }
  }

  @Test func shouldRefuseToExportWhileAFinalChapterCannotBeRead() async throws {
    let novel = UUID()
    let store = try Projection.store(try Projection.reconciler(), allowingFaults: true)
    _ = try await Projection.write(store) { transaction in
      _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
      _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: Canon(body: "One.")).finalize(in: &transaction)
    }
    let key = try NovelForgeKey.finalChapterKey(novel: novel, chapter: 2)
    try await Projection.set(key.ref, [CommonField.naturalKey.rawValue: key.stored, FinalChapterField.canon.rawValue: .string("unreadable")], in: store)
    await #expect(throws: ExportError.unreadableChapters(count: 1)) { try await store.exportManuscript(novel: novel) }
    await #expect(throws: ExportError.unreadableChapters(count: 1)) { try await store.exportPackage(novel: novel) }
  }

  @Test func shouldJoinChaptersWithARuleAndNameUntitledOnes() {
    let chapters = [ExportChapter(number: 2, title: nil, content: "Two."), ExportChapter(number: 1, title: "One", content: "One.")]
    #expect(Manuscript.markdown(of: chapters) == "# One\n\nOne.\n\n---\n\n# Chapter 2\n\nTwo.")
    #expect(Manuscript.markdown(of: []) == "")
  }

  private func seed(_ entry: ExportFixture.Case, in store: VaultStore) async throws {
    let novel = entry.novel
    _ = try await Projection.write(store) { transaction in
      _ = try NovelRecord(id: novel.id, name: novel.name, title: novel.title, brief: novel.brief, premise: novel.premise, themes: novel.themes).create(in: &transaction)
      for final in entry.finals {
        let canon = Canon(title: final.title, body: final.content)
        _ = try FinalChapterRecord(novel: novel.id, chapter: final.number, canon: canon).finalize(in: &transaction)
      }
      for draft in entry.drafts {
        let content = DraftContent(title: draft.title, body: draft.body, source: .known(.generated))
        _ = try DraftRecord(novel: novel.id, chapter: draft.chapter, content: content).create(in: &transaction)
      }
    }
    _ = try await Projection.write(store) { transaction in
      for final in entry.finals {
        guard let amendment = final.amendment else { continue }
        try FinalChapters.amend(novel: novel.id, chapter: final.number, ChapterAmendment(content: amendment.content, title: amendment.title), in: &transaction)
      }
    }
  }
}
