import Foundation
import MemoirCore
import ShadowCore
import ShadowStore
import Synchronization

final class MemoirTestClock: Sendable {
  private let date = Mutex(Date(timeIntervalSince1970: 1_700_000_000))

  var function: @Sendable () -> Date { { self.date.withLock { $0 } } }

  func advance(seconds: TimeInterval = 1) {
    date.withLock { $0 = $0.addingTimeInterval(seconds) }
  }
}

struct MemoirFixtureError: Error, CustomStringConvertible {
  let description: String
}

enum MemoirStoreFixture {
  static let quest = uuid("0190f3a0-0000-7000-8000-0000000000a1")
  static let metric = uuid("0190f3a0-0000-7000-8000-0000000000b1")

  static func uuid(_ text: String) -> UUID {
    guard let id = UUID(uuidString: text) else { preconditionFailure("\(text) is a valid UUID") }
    return id
  }

  static func commandID(_ number: Int) -> UUID {
    uuid(String(format: "0190f3a0-0000-7000-8000-%012x", number))
  }

  static func date(_ text: String) throws -> LocalDate {
    guard let date = LocalDate(isoString: text) else { throw MemoirFixtureError(description: "\(text) is not a date") }
    return date
  }

  static func decimal(_ text: String) throws -> DecimalText {
    guard let value = DecimalText(text) else { throw MemoirFixtureError(description: "\(text) is not a canonical decimal") }
    return value
  }

  static func currency(_ text: String) throws -> CurrencyCode {
    guard let code = CurrencyCode(text) else { throw MemoirFixtureError(description: "\(text) is not a currency code") }
    return code
  }

  static func category(_ text: String) throws -> CategoryKey {
    guard let key = CategoryKey(text) else { throw MemoirFixtureError(description: "\(text) is not a category key") }
    return key
  }

  static func fixture(_ path: String) throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appending(path: "Fixtures").appending(path: path))
  }

  static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "MemoirStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func exchange(_ first: VaultStore, _ second: VaultStore) async throws {
    let fromFirst = try await first.pendingChanges(limit: Int.max).map(\.line)
    let fromSecond = try await second.pendingChanges(limit: Int.max).map(\.line)
    _ = try await second.applyRemote(fromFirst)
    _ = try await first.applyRemote(fromSecond)
  }
}
