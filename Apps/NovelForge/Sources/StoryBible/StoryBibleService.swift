import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore

nonisolated struct StoryBibleService: Sendable {
  let store: VaultStore
  let novel: UUID

  func createPage(section: BiblePageSection, title: String, slug: String, body: String) async throws -> PageAddress {
    let novel = novel
    let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let frontmatter: [String: JSONValue]? = heading.isEmpty ? nil : ["title": .string(heading)]
    try await write { transaction in
      try Pages.create(novel: novel, section: section, slug: slug, frontmatter: frontmatter, body: body, in: &transaction)
    }
    return PageAddress(section: section, slug: slug.precomposedStringWithCanonicalMapping)
  }

  func savePage(_ address: PageAddress, title: String, body: String, basedOn revision: String?) async throws -> PageSaved {
    let novel = novel
    let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return try await write { transaction in
      let head = try Pages.versions(novel: novel, section: address.section, slug: address.slug, in: transaction).first(where: \.isHead)?.revision
      if let revision, revision != head { throw BibleWriteIssue.pageChanged(head: head) }
      guard let page = try Pages.get(novel: novel, section: address.section, slug: address.slug, in: transaction) else {
        throw DomainError.documentNotFound(section: address.section.rawValue, slug: address.slug)
      }
      var frontmatter = page.content.frontmatter ?? [:]
      frontmatter["title"] = heading.isEmpty ? nil : .string(heading)
      return try Pages.revise(novel: novel, section: address.section, slug: address.slug, frontmatter: frontmatter, body: body, in: &transaction)
    }
  }

  func removePage(_ address: PageAddress) async throws {
    let novel = novel
    try await write { transaction in try Pages.remove(novel: novel, section: address.section, slug: address.slug, in: &transaction) }
  }

  func restorePage(_ address: PageAddress) async throws {
    let novel = novel
    try await write { transaction in try Pages.restore(novel: novel, section: address.section, slug: address.slug, in: &transaction) }
  }

  func restoreVersion(_ address: PageAddress, revision: String) async throws {
    let novel = novel
    try await write { transaction in try Pages.restoreVersion(novel: novel, section: address.section, slug: address.slug, revision: revision, in: &transaction) }
  }

  func createEntity(key: String, type: EntityType, name: String, details: EntityDetails) async throws -> String {
    let novel = novel
    try await write { transaction in
      try Entities.createNew(novel: novel, entity: key, type: type, name: name, details, in: &transaction)
    }
    return key.precomposedStringWithCanonicalMapping
  }

  func editEntity(key: String, name: String?, details: EntityDetails) async throws {
    let novel = novel
    try await write { transaction in try Entities.edit(novel: novel, entity: key, name: name, details, in: &transaction) }
  }

  func removeEntity(_ key: String) async throws {
    let novel = novel
    try await write { transaction in try Entities.remove(novel: novel, entity: key, in: &transaction) }
  }

  func restoreEntity(_ key: String) async throws {
    let novel = novel
    try await write { transaction in try Entities.restore(novel: novel, entity: key, in: &transaction) }
  }

  @discardableResult
  private func write<Result: Sendable>(_ body: @Sendable (inout WriteTransaction) throws -> Result) async throws -> Result {
    do {
      return try await store.write { transaction in try body(&transaction) }
    } catch {
      if case .aborted(let cause) = error { throw cause }
      throw DomainError.store(error)
    }
  }
}
