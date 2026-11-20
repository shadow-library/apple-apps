import Foundation
import ShadowText

public struct NovelPackage: Sendable, Equatable {
  public let id: String
  public let filename: String
  public let bytes: Data
  public let chapterCount: Int
  public let manifest: String
  public let files: [String]
}

extension NovelPackage {
  private static let schemaVersion = 1

  /// apps/novel-forge-server/src/modules/export/novel-package.service.ts:93-139 without images: chapter files, then `manifest.json`, in a stored zip.
  /// Chapters with no text are left out; a package of none is EXP_001.
  public static func build(novel: ExportNovel, chapters: [ExportChapter]) throws(ExportError) -> NovelPackage {
    let usable = chapters.filter { !$0.content.jsTrim().isEmpty }.sorted { $0.number < $1.number }
    guard !usable.isEmpty else { throw .noChapters }

    var entries = [ZipEntry]()
    var listed = [OrderedJSON]()
    for chapter in usable {
      let file = "chapters/\(paddedNumber(chapter.number)).md"
      entries.append(ZipEntry(name: file, data: Data(chapter.content.utf8)))
      listed.append(.object(OrderedJSONObject([(key: "title", value: .string(heading(of: chapter))), (key: "file", value: .string(file))])))
    }

    let id = "\(slug(of: novel.title?.jsTrim().nonEmpty ?? novel.name).nonEmpty ?? "novel")-\(novel.id.uuidString.lowercased())"
    var members: [(key: String, value: OrderedJSON)] = [
      (key: "schemaVersion", value: .int(Int64(schemaVersion))),
      (key: "id", value: .string(id)),
      (key: "title", value: .string(novel.title?.jsTrim().nonEmpty ?? novel.name)),
    ]
    if let description = novel.brief?.jsTrim().nonEmpty ?? novel.premise?.jsTrim().nonEmpty { members.append((key: "description", value: .string(description))) }
    if let tags = novel.themes?.filter({ !$0.isEmpty }), !tags.isEmpty { members.append((key: "tags", value: .array(tags.map(OrderedJSON.string)))) }
    members.append((key: "chapters", value: .array(listed)))

    let manifest = OrderedJSON.object(OrderedJSONObject(members)).indentedText
    entries.append(ZipEntry(name: "manifest.json", data: Data(manifest.utf8)))
    return NovelPackage(id: id, filename: "\(id).novel", bytes: try StoredZip.write(entries), chapterCount: usable.count, manifest: manifest, files: entries.map(\.name))
  }

  private static func paddedNumber(_ number: Int) -> String {
    let digits = String(number)
    return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
  }

  private static func heading(of chapter: ExportChapter) -> String {
    chapter.title?.jsTrim().nonEmpty ?? "Chapter \(chapter.number)"
  }

  static func slug(of value: String) -> String {
    var slug = ""
    var pendingBreak = false
    for scalar in value.jsToLowerCase().unicodeScalars {
      guard (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39) else {
        pendingBreak = true
        continue
      }
      if pendingBreak && !slug.isEmpty { slug += "-" }
      pendingBreak = false
      slug.unicodeScalars.append(scalar)
    }
    return slug
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

extension OrderedJSON {
  /// `JSON.stringify(value, null, 2)`.
  fileprivate var indentedText: String {
    var out = ""
    append(to: &out, depth: 0)
    return out
  }

  private func append(to out: inout String, depth: Int) {
    let inner = String(repeating: "  ", count: depth + 1)
    switch self {
    case .array(let items) where !items.isEmpty:
      out += "[\n"
      for (index, item) in items.enumerated() {
        out += inner
        item.append(to: &out, depth: depth + 1)
        out += index == items.count - 1 ? "\n" : ",\n"
      }
      out += String(repeating: "  ", count: depth) + "]"
    case .object(let object) where !object.entries.isEmpty:
      out += "{\n"
      for (index, entry) in object.entries.enumerated() {
        out += inner + OrderedJSON.string(entry.key).jsonText + ": "
        entry.value.append(to: &out, depth: depth + 1)
        out += index == object.entries.count - 1 ? "\n" : ",\n"
      }
      out += String(repeating: "  ", count: depth) + "}"
    default: out += jsonText
    }
  }
}
