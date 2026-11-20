import Foundation
import ShadowSync

struct S3Listing: Sendable, Equatable {
  struct Entry: Sendable, Equatable {
    let name: String
    let size: String?
  }

  let entries: [Entry]
  let isTruncated: Bool
  let nextContinuationToken: String?

  init(entries: [Entry], isTruncated: Bool, nextContinuationToken: String?) {
    self.entries = entries
    self.isTruncated = isTruncated
    self.nextContinuationToken = nextContinuationToken
  }

  init(xml data: Data) throws(StorageError) {
    guard let root = S3XMLNode.parse(data), root.name == "ListBucketResult" else { throw .unavailable("The storage service returned a listing that could not be read.") }
    let isURLEncoded = root.value("EncodingType") == "url"
    entries = root.children("Contents").compactMap { contents in
      guard let raw = contents.value("Key") else { return nil }
      guard isURLEncoded else { return Entry(name: raw, size: contents.value("Size")) }
      return S3URIEncoding.decode(raw, plusAsSpace: true).map { Entry(name: $0, size: contents.value("Size")) }
    }
    isTruncated = root.value("IsTruncated")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    nextContinuationToken = root.value("NextContinuationToken").flatMap { $0.isEmpty ? nil : $0 }
  }

  func page(namePrefix: String, prefix: String) throws(StorageError) -> ListPage {
    for (previous, entry) in zip(entries, entries.dropFirst()) where !previous.name.utf8.lexicographicallyPrecedes(entry.name.utf8) {
      throw .underlying("The storage service listed objects out of key order, so this bucket cannot hold a vault.")
    }
    var objects: [StorageObject] = []
    for entry in entries where entry.name.utf8.starts(with: namePrefix.utf8) {
      guard let key = ObjectKey(String(decoding: entry.name.utf8.dropFirst(namePrefix.utf8.count), as: UTF8.self)), key.hasPrefix(prefix) else { continue }
      guard let size = entry.size.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), size >= 0 else {
        throw .unavailable("The storage service listed \(key) without a size.")
      }
      objects.append(StorageObject(key: key, size: size))
    }
    return ListPage(objects: objects, next: try next())
  }

  private func next() throws(StorageError) -> ListCursor? {
    guard isTruncated else { return nil }
    if let nextContinuationToken { return S3ListCursor.continuation(nextContinuationToken).cursor }
    guard let last = entries.last else { throw .unavailable("The storage service cut a listing short without a way to continue it.") }
    return S3ListCursor.startAfter(last.name).cursor
  }
}

enum S3ListCursor: Sendable, Equatable {
  case continuation(String)
  case startAfter(String)

  private static let continuationTag: Character = "t"
  private static let startAfterTag: Character = "a"

  init(_ cursor: ListCursor) throws(StorageError) {
    let body = String(cursor.token.dropFirst())
    switch cursor.token.first {
    case Self.continuationTag where !body.isEmpty: self = .continuation(body)
    case Self.startAfterTag where !body.isEmpty: self = .startAfter(body)
    default: throw .underlying("The list cursor was not made by this provider.")
    }
  }

  var cursor: ListCursor {
    switch self {
    case .continuation(let token): ListCursor(token: String(Self.continuationTag) + token)
    case .startAfter(let name): ListCursor(token: String(Self.startAfterTag) + name)
    }
  }

  var queryItem: (name: String, value: String) {
    switch self {
    case .continuation(let token): ("continuation-token", token)
    case .startAfter(let name): ("start-after", name)
    }
  }
}
