import Foundation

struct DriveFileResource: Decodable, Sendable {
  let id: String
  let name: String?
  let size: Int?
  let version: Int64?
  let modifiedTime: Date?
  let trashed: Bool?
  let appProperties: [String: String]?

  enum CodingKeys: String, CodingKey {
    case id, name, size, version, modifiedTime, trashed, appProperties
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    size = try Self.integer(Int.self, in: container, forKey: .size)
    version = try Self.integer(Int64.self, in: container, forKey: .version)
    modifiedTime = try container.decodeIfPresent(String.self, forKey: .modifiedTime).flatMap(DriveTime.parse)
    trashed = try container.decodeIfPresent(Bool.self, forKey: .trashed)
    appProperties = try container.decodeIfPresent([String: String].self, forKey: .appProperties)
  }

  private static func integer<Value: FixedWidthInteger & Decodable>(_ type: Value.Type, in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Value? {
    if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Value(text) }
    return try container.decodeIfPresent(Value.self, forKey: key)
  }
}

struct DriveChange: Decodable, Sendable {
  let changeType: String?
  let removed: Bool?
  let fileId: String?
  let file: DriveFileResource?
}

struct DriveChangePage: Decodable, Sendable {
  let changes: [DriveChange]
  let nextPageToken: String?
  let newStartPageToken: String?

  enum CodingKeys: String, CodingKey {
    case changes, nextPageToken, newStartPageToken
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    changes = try container.decodeIfPresent([DriveChange].self, forKey: .changes) ?? []
    nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    newStartPageToken = try container.decodeIfPresent(String.self, forKey: .newStartPageToken)
  }
}

struct DriveFileListPage: Decodable, Sendable {
  let files: [DriveFileResource]
  let nextPageToken: String?
  let incompleteSearch: Bool

  enum CodingKeys: String, CodingKey {
    case files, nextPageToken, incompleteSearch
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    files = try container.decodeIfPresent([DriveFileResource].self, forKey: .files) ?? []
    nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    incompleteSearch = try container.decodeIfPresent(Bool.self, forKey: .incompleteSearch) ?? false
  }
}

struct DriveStartPageToken: Decodable, Sendable {
  let startPageToken: String
}

struct DriveErrorBody: Decodable, Sendable {
  struct Detail: Decodable, Sendable {
    let reason: String?
  }

  struct Payload: Decodable, Sendable {
    let errors: [Detail]?
    let details: [Detail]?
  }

  let error: Payload

  static func reasons(in body: Data) -> [String] {
    guard let decoded = try? JSONDecoder().decode(Self.self, from: body) else { return [] }
    return ((decoded.error.errors ?? []) + (decoded.error.details ?? [])).compactMap(\.reason)
  }
}

struct DriveFileMetadata: Encodable, Sendable {
  let name: String
  let parents: [String]
  let mimeType: String
  let appProperties: [String: String]

  func encoded() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { preconditionFailure("File metadata of strings always encodes.") }
    return data
  }
}

enum DriveTime {
  private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let whole = Date.ISO8601FormatStyle()

  static func parse(_ value: String) -> Date? {
    (try? fractional.parse(value)) ?? (try? whole.parse(value))
  }
}
