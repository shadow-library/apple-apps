import Foundation
import ShadowSync

public struct StorageConformanceViolation: Error, CustomStringConvertible, Sendable {
  public let rule: String
  public let detail: String

  public var description: String { "storage conformance violated: \(rule) (\(detail))" }
}

public enum StorageProviderConformance {
  public enum Consistency: Sendable {
    case strong
    case eventual
  }

  public static func verify(consistency: Consistency = .strong, _ makeProvider: () async throws -> any StorageProvider) async throws {
    let checker = Checker(provider: try await makeProvider(), consistency: consistency)
    try await checker.roundTrips()
    try await checker.overwrites()
    try await checker.conditionalPuts()
    try await checker.missingGet()
    try await checker.deletes()
    try await checker.prefixFiltering()
    try await checker.ordering()
    try await checker.pagination()
    try await checker.allowedCharacters()
    try await checker.sizeLimit()
    checker.changeNoticesAreAvailable()
  }
}

private final class Checker {
  private static let maxPolls = 2000
  private static let maxPages = 10_000

  private let provider: any StorageProvider
  private let consistency: StorageProviderConformance.Consistency
  private var everPut: Set<ObjectKey> = []

  init(provider: any StorageProvider, consistency: StorageProviderConformance.Consistency) {
    self.provider = provider
    self.consistency = consistency
  }

  func roundTrips() async throws {
    let rule = "a put object reads back byte for byte"
    let limit = provider.capabilities.maxObjectBytes
    var expected: [StorageObject] = []
    for (name, size) in [("empty", 0), ("small", 37), ("one-mebibyte", 1_048_576)] where size <= limit {
      let key = try makeKey("roundtrip/\(name)")
      let data = payload(size, salt: size)
      let receipt = try await put(key, data, .overwrite, rule)
      if provider.capabilities.reportsServerTime && receipt.serverTime == nil { throw violation("a provider that reports server time puts with a server time", key.rawValue) }
      guard try await get(key, rule) == data else { throw violation(rule, "\(name) object differs") }
      expected.append(StorageObject(key: key, size: size))
    }
    try await expectListing("a listing shows put objects with their sizes", prefix: "roundtrip/", equals: expected.sorted { $0.key < $1.key })
  }

  func overwrites() async throws {
    let rule = "an overwriting put replaces the object"
    let key = try makeKey("overwrite/a")
    _ = try await put(key, payload(10, salt: 1), .overwrite, rule)
    _ = try await put(key, payload(20, salt: 2), .overwrite, rule)
    guard try await get(key, rule) == payload(20, salt: 2) else { throw violation(rule, "second value not returned") }
    _ = try await put(key, Data(), .overwrite, rule)
    guard try await get(key, rule).isEmpty else { throw violation(rule, "empty value not returned") }
  }

  func conditionalPuts() async throws {
    let key = try makeKey("conditional/a")
    let first = payload(8, salt: 3)
    _ = try await put(key, first, .ifAbsent, "an ifAbsent put succeeds when the key is absent")
    guard provider.capabilities.supportsPutIfAbsent else { return }
    let rule = "an ifAbsent put throws alreadyExists when the key exists"
    try await expectError(rule, matches: { $0 == .alreadyExists(key) }, body: { _ = try await self.provider.put(key, data: payload(8, salt: 4), condition: .ifAbsent) })
    guard try await get(key, rule) == first else { throw violation(rule, "a rejected put changed the object") }
    let overwritten = try makeKey("conditional/b")
    _ = try await put(overwritten, first, .overwrite, rule)
    try await expectError(rule, matches: { $0 == .alreadyExists(overwritten) }, body: { _ = try await self.provider.put(overwritten, data: first, condition: .ifAbsent) })
  }

  func missingGet() async throws {
    let key = try makeKey("missing/a")
    try await expectError("get of a missing key throws notFound", matches: { $0 == .notFound(key) }, body: { _ = try await self.provider.get(key) })
  }

  func deletes() async throws {
    let rule = "delete removes objects and ignores missing keys"
    let keys = try ["delete/a", "delete/b", "delete/c"].map { try self.makeKey($0) }
    let missing = try makeKey("delete/never-put")
    try await delete([missing], rule)
    try await delete([], rule)
    for key in keys { _ = try await put(key, payload(5, salt: 5), .overwrite, rule) }
    try await delete([keys[0], missing], rule)
    try await expectMissing(keys[0], rule)
    guard try await get(keys[1], rule) == payload(5, salt: 5) else { throw violation(rule, "an undeleted object changed") }
    try await delete([keys[0], keys[1], keys[2]], rule)
    try await delete([keys[0], keys[1], keys[2]], rule)
    for key in keys { try await expectMissing(key, rule) }
    try await expectListing(rule, prefix: "delete/", equals: [])
    _ = try await put(keys[0], payload(6, salt: 6), .ifAbsent, rule)
    guard try await get(keys[0], rule) == payload(6, salt: 6) else { throw violation(rule, "a deleted key cannot be reused") }
  }

  func prefixFiltering() async throws {
    let rule = "a listing returns exactly the objects whose key starts with the prefix"
    let names = ["prefix/a/x", "prefix/a/y", "prefix/ab/z", "prefix/b/q"]
    for name in names { _ = try await put(try makeKey(name), payload(3, salt: 7), .overwrite, rule) }
    let size = 3
    func expected(_ prefix: String) throws -> [StorageObject] {
      try names.filter { $0.hasPrefix(prefix) }.map { StorageObject(key: try makeKey($0), size: size) }.sorted { $0.key < $1.key }
    }
    for prefix in ["prefix/a/", "prefix/a", "prefix/", "prefix/b/q", "prefix/zzz", "prefix/a/x/", "prefi"] {
      try await expectListing(rule, prefix: prefix, equals: try expected(prefix))
    }
  }

  func ordering() async throws {
    let rule = "a listing is in ascending byte order of the key"
    let names = ["Z", "a", "B", "_x", "-y", ".z", "0", "a.b", "a-b", "a_b", "m/n", "m0", "m.q"]
    var generator = SeededGenerator(seed: 0x0DE4)
    for name in generator.shuffled(names) { _ = try await put(try makeKey("order/\(name)"), payload(1, salt: 8), .overwrite, rule) }
    let expected = try names.map { try makeKey("order/\($0)") }.sorted().map { StorageObject(key: $0, size: 1) }
    try await expectListing(rule, prefix: "order/", equals: expected)
  }

  func pagination() async throws {
    let rule = "a paginated listing of 250 objects returns each exactly once in order"
    let size = min(16, provider.capabilities.maxObjectBytes)
    var generator = SeededGenerator(seed: 0x9A6E)
    let keys = try (0..<250).map { try makeKey("page/g\($0 / 25)/k\($0)") }
    for key in generator.shuffled(keys) { _ = try await put(key, payload(size, salt: 9), .overwrite, rule) }
    try await expectListing(rule, prefix: "page/", equals: keys.sorted().map { StorageObject(key: $0, size: size) })
    guard consistency == .strong else { return }
    let drained = try await listAll("conformance/page/", rule)
    guard drained.map(\.key) == keys.sorted() else { throw violation(rule, "listAll returned \(drained.count) objects") }
  }

  func allowedCharacters() async throws {
    let rule = "keys may use every allowed character"
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    var maximal = "chars/long"
    let budget = ObjectKey.maxUTF8Length - "conformance/".utf8.count
    while maximal.utf8.count < budget { maximal += "/" + String(repeating: "k", count: min(100, budget - maximal.utf8.count - 1)) }
    let keys = try [
      "chars/\(alphabet)", "chars/nested/\(alphabet.reversed().map(String.init).joined())", "chars/dots/..e/e../...", "chars/-/_/.x", maximal,
    ].map { try self.makeKey($0) }
    for (index, key) in keys.enumerated() {
      _ = try await put(key, payload(4, salt: 10 + index), .overwrite, rule)
      guard try await get(key, rule) == payload(4, salt: 10 + index) else { throw violation(rule, "\(key) did not round trip") }
    }
    try await expectListing(rule, prefix: "chars/", equals: keys.sorted().map { StorageObject(key: $0, size: 4) })
  }

  func sizeLimit() async throws {
    let limit = provider.capabilities.maxObjectBytes
    guard limit < 4_194_304 else { return }
    let rule = "a put larger than maxObjectBytes throws tooLarge"
    let atLimit = try makeKey("limit/at")
    let over = try makeKey("limit/over")
    _ = try await put(atLimit, payload(limit, salt: 11), .overwrite, rule)
    try await expectError(
      rule, matches: { $0 == .tooLarge(over, limit: limit) }, body: { _ = try await self.provider.put(over, data: payload(limit + 1, salt: 12), condition: .overwrite) })
    try await expectMissing(over, rule)
  }

  func changeNoticesAreAvailable() {
    _ = provider.changeNotices()
  }

  private func makeKey(_ raw: String) throws -> ObjectKey {
    guard let key = ObjectKey("conformance/\(raw)") else { throw violation("test keys are valid", raw) }
    return key
  }

  private func violation(_ rule: String, _ detail: String) -> StorageConformanceViolation {
    StorageConformanceViolation(rule: rule, detail: detail)
  }

  private func payload(_ count: Int, salt: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8 &+ salt) })
  }

  private func step<T>(_ rule: String, _ body: () async throws(StorageError) -> T) async throws -> T {
    do {
      return try await body()
    } catch {
      throw violation(rule, "unexpected \(error)")
    }
  }

  private func put(_ key: ObjectKey, _ data: Data, _ condition: PutCondition, _ rule: String) async throws -> PutReceipt {
    everPut.insert(key)
    return try await step(rule) { () async throws(StorageError) -> PutReceipt in try await self.provider.put(key, data: data, condition: condition) }
  }

  private func get(_ key: ObjectKey, _ rule: String) async throws -> Data {
    try await step(rule) { () async throws(StorageError) -> Data in try await self.provider.get(key) }
  }

  private func delete(_ keys: [ObjectKey], _ rule: String) async throws {
    try await step(rule) { () async throws(StorageError) -> Void in try await self.provider.delete(keys) }
  }

  private func listAll(_ prefix: String, _ rule: String) async throws -> [StorageObject] {
    try await step(rule) { () async throws(StorageError) -> [StorageObject] in try await self.provider.listAll(prefix: prefix) }
  }

  private func expectError(_ rule: String, matches: (StorageError) -> Bool, body: () async throws -> Void) async throws {
    do {
      try await body()
    } catch {
      guard let error = error as? StorageError, matches(error) else { throw violation(rule, "threw \(error)") }
      return
    }
    throw violation(rule, "did not throw")
  }

  private func expectMissing(_ key: ObjectKey, _ rule: String) async throws {
    for _ in 0..<Self.maxPolls {
      do {
        _ = try await provider.get(key)
      } catch {
        guard error == .notFound(key) else { throw violation(rule, "get of a deleted key threw \(error)") }
        return
      }
      guard consistency == .eventual else { break }
      await Task.yield()
    }
    throw violation(rule, "\(key) is still readable after delete")
  }

  private func drain(_ prefix: String, _ rule: String) async throws -> [StorageObject] {
    var objects: [StorageObject] = []
    var cursor: ListCursor?
    for _ in 0..<Self.maxPages {
      let page = try await step(rule) { () async throws(StorageError) -> ListPage in try await self.provider.list(prefix: prefix, after: cursor) }
      for object in page.objects {
        guard object.key.hasPrefix(prefix) else { throw violation(rule, "\(object.key) does not start with '\(prefix)'") }
        guard everPut.contains(object.key) else { throw violation("a listing never invents an object", "\(object.key)") }
        if let last = objects.last, object.key <= last.key { throw violation("a listing is ascending and returns each object at most once", "\(object.key) after \(last.key)") }
        objects.append(object)
      }
      guard let next = page.next else { return objects }
      guard next != cursor else { throw violation(rule, "cursor \(next.token) did not advance") }
      cursor = next
    }
    throw violation(rule, "listing did not finish within \(Self.maxPages) pages")
  }

  private func expectListing(_ rule: String, prefix: String, equals expected: [StorageObject]) async throws {
    let prefix = "conformance/\(prefix)"
    var observed: [StorageObject] = []
    for _ in 0..<Self.maxPolls {
      observed = try await drain(prefix, rule)
      if observed == expected { return }
      guard consistency == .eventual else { break }
      await Task.yield()
    }
    throw violation(rule, "prefix '\(prefix)' expected \(expected.map(\.key.rawValue)) but listed \(observed.map(\.key.rawValue))")
  }
}
