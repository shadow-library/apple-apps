import Foundation
import ShadowCore
import ShadowText

extension ChatLookupReader {
  // tools/get-bible-document.tool.ts:17
  func bibleDocument(section: BiblePageSection, slug: String) throws(ChatLookupFailure) -> String {
    guard let (page, revision) = try head(PageRecord.self, PageRecord.ref(novel: novel, section: section, slug: slug)) else {
      return "Bible document not found: \(section.rawValue)/\(slug)"
    }
    var lines = ["**\(section.rawValue)/\(page.slug)** (rev \(revision))"]
    if let frontmatter = page.content.frontmatter, !frontmatter.isEmpty {
      lines.append("Frontmatter: \(JSONBText.value(.object(frontmatter)).jsonText)")
    }
    lines.append(page.content.body ?? "(empty)")
    return lines.joined(separator: "\n")
  }

  // tools/get-volume.tool.ts:14
  func volume(key: String) throws(ChatLookupFailure) -> String {
    guard let (volume, _) = try head(VolumeRecord.self, VolumeRecord.ref(novel: novel, volume: key)) else { return "Volume not found: \(key)" }
    var lines = ["**\(volume.volume)**: \(volume.title ?? "(untitled)") (ordinal \(volume.ordinal))"]
    if let objective = ChatPack.present(volume.objective) { lines.append("Goal: \(objective)") }
    if let body = ChatPack.present(volume.body) { lines.append(body) }
    return lines.joined(separator: "\n")
  }

  // tools/get-entity.tool.ts:15; the vault keeps no aliases, relationships or first-seen chapter, so the card leaves them out
  func entity(key: String) throws(ChatLookupFailure) -> String {
    guard let (entity, _) = try head(EntityRecord.self, EntityRecord.ref(novel: novel, entity: key)) else { return "Entity not found: \(key)" }
    var lines = ["**\(entity.name)** (\(entity.type.rawValue), \(entity.status ?? "active"))"]
    if let body = ChatPack.present(entity.body ?? entity.notes) { lines.append(body) }
    return lines.joined(separator: "\n")
  }
}
