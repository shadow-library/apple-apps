import Foundation
import ShadowSync
import ShadowTestSupport
import Testing

private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
  let directory = FileManager.default.temporaryDirectory.appending(path: "shadow-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: directory) }
  return try await body(directory)
}

private func key(_ raw: String) throws -> ObjectKey {
  try #require(ObjectKey(raw))
}

private func ifAbsentFailure(_ provider: LocalFolderProvider, _ key: ObjectKey, _ data: Data) async -> StorageError? {
  do {
    _ = try await provider.put(key, data: data, condition: .ifAbsent)
    return nil
  } catch {
    return error
  }
}

@Suite("InMemoryStorageProvider")
struct InMemoryStorageProviderTests {
  @Test("should satisfy the conformance suite")
  func shouldConform() async throws {
    try await StorageProviderConformance.verify { InMemoryStorageProvider(pageSize: 40) }
  }

  @Test("should satisfy the conformance suite with a finite object limit")
  func shouldConformWithLimit() async throws {
    try await StorageProviderConformance.verify { InMemoryStorageProvider(maxObjectBytes: 1024, pageSize: 7) }
  }

  @Test("should count calls per operation")
  func shouldCountCalls() async throws {
    let provider = InMemoryStorageProvider()
    let object = try key("a")
    _ = try await provider.put(object, data: Data([1]), condition: .overwrite)
    _ = try await provider.get(object)
    _ = try await provider.get(object)
    _ = try await provider.list(prefix: "", after: nil)
    try await provider.delete([object])
    let counts = provider.callCounts
    #expect(counts.list == 1)
    #expect(counts.get == 2)
    #expect(counts.put == 1)
    #expect(counts.delete == 1)
  }

  @Test("should report server time only when a clock is injected")
  func shouldReportServerTime() async throws {
    let instant = Date(timeIntervalSince1970: 1_000)
    let clocked = InMemoryStorageProvider(serverClock: { instant })
    let plain = InMemoryStorageProvider()
    let object = try key("a")
    #expect(clocked.capabilities.reportsServerTime)
    let stamped = try await clocked.put(object, data: Data(), condition: .overwrite)
    #expect(stamped.serverTime == instant)
    #expect(!plain.capabilities.reportsServerTime)
    let unstamped = try await plain.put(object, data: Data(), condition: .overwrite)
    #expect(unstamped.serverTime == nil)
  }

  @Test("should reject objects over the limit")
  func shouldRejectTooLarge() async throws {
    let provider = InMemoryStorageProvider(maxObjectBytes: 4, classPolicy: .iCloud)
    let object = try key("a")
    #expect(provider.capabilities.classPolicy == .iCloud)
    await #expect(throws: StorageError.tooLarge(object, limit: 4)) { try await provider.put(object, data: Data(count: 5), condition: .overwrite) }
  }
}

@Suite("LocalFolderProvider")
struct LocalFolderProviderTests {
  @Test("should satisfy the conformance suite")
  func shouldConform() async throws {
    try await withTemporaryDirectory { directory in
      try await StorageProviderConformance.verify { try LocalFolderProvider(root: directory) }
    }
  }

  @Test("should satisfy the conformance suite with small pages")
  func shouldConformWithSmallPages() async throws {
    try await withTemporaryDirectory { directory in
      try await StorageProviderConformance.verify { try LocalFolderProvider(root: directory, pageSize: 40) }
    }
  }

  @Test("should declare local capabilities")
  func shouldDeclareCapabilities() async throws {
    try await withTemporaryDirectory { directory in
      let capabilities = try LocalFolderProvider(root: directory).capabilities
      #expect(!capabilities.pushesChangeNotices)
      #expect(capabilities.supportsPutIfAbsent)
      #expect(!capabilities.hasChangeFeed)
      #expect(!capabilities.reportsServerTime)
      #expect(capabilities.classPolicy == .unrestricted)
    }
  }

  @Test("should let exactly one of 50 concurrent ifAbsent puts win")
  func shouldAllowOneConcurrentIfAbsent() async throws {
    try await withTemporaryDirectory { directory in
      let provider = try LocalFolderProvider(root: directory)
      let object = try key("race/target")
      let outcomes = await withTaskGroup(of: StorageError?.self) { group in
        for index in 0..<50 {
          group.addTask { await ifAbsentFailure(provider, object, Data([UInt8(index)])) }
        }
        return await group.reduce(into: []) { $0.append($1) }
      }
      #expect(outcomes.filter { $0 == nil }.count == 1)
      #expect(outcomes.compactMap { $0 }.allSatisfy { $0 == .alreadyExists(object) })
      #expect(try await provider.get(object).count == 1)
    }
  }

  @Test("should never list temporary files")
  func shouldHideTemporaryFiles() async throws {
    try await withTemporaryDirectory { directory in
      let provider = try LocalFolderProvider(root: directory)
      let temporary = directory.appending(path: ".tmp~", directoryHint: .isDirectory)
      try Data([1]).write(to: temporary.appending(path: "half-written"))
      _ = try await provider.put(try key("a/b"), data: Data([2]), condition: .overwrite)
      #expect(try await provider.listAll(prefix: "").map(\.key.rawValue) == ["a/b"])
      let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
      #expect(leftovers == ["half-written"])
    }
  }

  @Test("should ignore foreign files with invalid names")
  func shouldIgnoreForeignFiles() async throws {
    try await withTemporaryDirectory { directory in
      let provider = try LocalFolderProvider(root: directory)
      try Data([1]).write(to: directory.appending(path: "bad name.txt"))
      try Data([1]).write(to: directory.appending(path: "tilde~"))
      try FileManager.default.createDirectory(at: directory.appending(path: "dir with space"), withIntermediateDirectories: true)
      try Data([1]).write(to: directory.appending(path: "dir with space/file"))
      _ = try await provider.put(try key("good"), data: Data([2]), condition: .overwrite)
      #expect(try await provider.listAll(prefix: "").map(\.key.rawValue) == ["good"])
    }
  }

  @Test("should see earlier objects after reopening the same root")
  func shouldSurviveReopen() async throws {
    try await withTemporaryDirectory { directory in
      let first = try LocalFolderProvider(root: directory)
      _ = try await first.put(try key("x/y"), data: Data([7, 8]), condition: .overwrite)
      let second = try LocalFolderProvider(root: directory)
      #expect(try await second.get(try key("x/y")) == Data([7, 8]))
      #expect(try await second.listAll(prefix: "") == [StorageObject(key: try key("x/y"), size: 2)])
    }
  }

  @Test("should leave directories in place when deleting")
  func shouldKeepDirectoriesOnDelete() async throws {
    try await withTemporaryDirectory { directory in
      let provider = try LocalFolderProvider(root: directory)
      _ = try await provider.put(try key("d/e/f"), data: Data(), condition: .overwrite)
      try await provider.delete([try key("d/e/f"), try key("d/e")])
      #expect(FileManager.default.fileExists(atPath: directory.appending(path: "d/e").path))
      #expect(try await provider.listAll(prefix: "").isEmpty)
    }
  }

  @Test("should reject a key beside its segment-ancestor or descendant")
  func shouldReportKeyConflicts() async throws {
    try await withTemporaryDirectory { directory in
      let provider = try LocalFolderProvider(root: directory)
      _ = try await provider.put(try key("a"), data: Data([1]), condition: .overwrite)
      await #expect(throws: StorageError.keyConflict(try key("a/b"))) { try await provider.put(try key("a/b"), data: Data([2]), condition: .overwrite) }
      _ = try await provider.put(try key("c/d"), data: Data([1]), condition: .overwrite)
      await #expect(throws: StorageError.keyConflict(try key("c"))) { try await provider.put(try key("c"), data: Data([2]), condition: .ifAbsent) }
      #expect(try await provider.get(try key("a")) == Data([1]))
      #expect(try await provider.listAll(prefix: "").map(\.key.rawValue) == ["a", "c/d"])
    }
  }

  @Test("should not follow a symlinked directory out of the root")
  func shouldRejectSymlinkedDirectoryEscape() async throws {
    try await withTemporaryDirectory { directory in
      try await withTemporaryDirectory { outside in
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([9]).write(to: outside.appending(path: "x"))
        let provider = try LocalFolderProvider(root: directory)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "a"), withDestinationURL: outside)
        await #expect(throws: StorageError.self) { try await provider.get(try key("a/x")) }
        await #expect(throws: StorageError.self) { try await provider.put(try key("a/y"), data: Data([1]), condition: .overwrite) }
        await #expect(throws: StorageError.self) { try await provider.delete([try key("a/x")]) }
        #expect(try await provider.listAll(prefix: "").isEmpty)
        #expect(try Data(contentsOf: outside.appending(path: "x")) == Data([9]))
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "y").path))
      }
    }
  }

  @Test("should follow a symlinked directory that stays inside the root")
  func shouldAllowSymlinkedDirectoryInside() async throws {
    try await withTemporaryDirectory { directory in
      let provider = try LocalFolderProvider(root: directory)
      _ = try await provider.put(try key("real/x"), data: Data([4]), condition: .overwrite)
      try FileManager.default.createSymbolicLink(at: directory.appending(path: "link"), withDestinationURL: directory.appending(path: "real"))
      #expect(try await provider.get(try key("link/x")) == Data([4]))
      #expect(try await provider.listAll(prefix: "").map(\.key.rawValue) == ["real/x"])
    }
  }

  @Test("should treat a symlinked file as no object")
  func shouldIgnoreSymlinkedFile() async throws {
    try await withTemporaryDirectory { directory in
      try await withTemporaryDirectory { outside in
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appending(path: "secret")
        try Data([9]).write(to: secret)
        let provider = try LocalFolderProvider(root: directory)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "f"), withDestinationURL: secret)
        await #expect(throws: StorageError.notFound(try key("f"))) { try await provider.get(try key("f")) }
        await #expect(throws: StorageError.keyConflict(try key("f"))) { try await provider.put(try key("f"), data: Data([1]), condition: .overwrite) }
        try await provider.delete([try key("f")])
        #expect(try await provider.listAll(prefix: "").isEmpty)
        #expect(try Data(contentsOf: secret) == Data([9]))
      }
    }
  }

  @Test("should reject keys that alias an existing key on a case-insensitive volume")
  func shouldRejectCaseAliases() async throws {
    try await withTemporaryDirectory { directory in
      let provider = try LocalFolderProvider(root: directory)
      let sensitive = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
      guard sensitive == false else { return }
      _ = try await provider.put(try key("case/foo"), data: Data([1]), condition: .overwrite)
      await #expect(throws: StorageError.notFound(try key("case/Foo"))) { try await provider.get(try key("case/Foo")) }
      await #expect(throws: StorageError.keyConflict(try key("case/Foo"))) { try await provider.put(try key("case/Foo"), data: Data([2]), condition: .overwrite) }
      await #expect(throws: StorageError.keyConflict(try key("case/Foo"))) { try await provider.put(try key("case/Foo"), data: Data([2]), condition: .ifAbsent) }
      await #expect(throws: StorageError.keyConflict(try key("Case/x"))) { try await provider.put(try key("Case/x"), data: Data([2]), condition: .overwrite) }
      try await provider.delete([try key("case/Foo")])
      #expect(try await provider.get(try key("case/foo")) == Data([1]))
      #expect(try await provider.listAll(prefix: "").map(\.key.rawValue) == ["case/foo"])
    }
  }

  @Test("should remove stale temporary files on open and keep fresh ones")
  func shouldCleanStaleTemporaryFiles() async throws {
    try await withTemporaryDirectory { directory in
      _ = try LocalFolderProvider(root: directory)
      let temporary = directory.appending(path: ".tmp~", directoryHint: .isDirectory)
      let stale = temporary.appending(path: "stale")
      let fresh = temporary.appending(path: "fresh")
      try Data([1]).write(to: stale)
      try Data([1]).write(to: fresh)
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: stale.path)
      _ = try LocalFolderProvider(root: directory)
      #expect(!FileManager.default.fileExists(atPath: stale.path))
      #expect(FileManager.default.fileExists(atPath: fresh.path))
    }
  }

  @Test("should leave no temporary files behind after puts")
  func shouldLeaveNoTemporaryFiles() async throws {
    try await withTemporaryDirectory { directory in
      let provider = try LocalFolderProvider(root: directory)
      let object = try key("t/a")
      _ = try await provider.put(object, data: Data([1]), condition: .overwrite)
      await #expect(throws: StorageError.alreadyExists(object)) { try await provider.put(object, data: Data([2]), condition: .ifAbsent) }
      await #expect(throws: StorageError.keyConflict(try key("t"))) { try await provider.put(try key("t"), data: Data([2]), condition: .overwrite) }
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: ".tmp~").path).isEmpty)
    }
  }

  @Test("should list only under the prefix across nested directories")
  func shouldListByPrefix() async throws {
    try await withTemporaryDirectory { directory in
      let provider = try LocalFolderProvider(root: directory)
      for raw in ["a/b/c", "a/b2", "a/d/e", "ab/x", "z"] { _ = try await provider.put(try key(raw), data: Data([1]), condition: .overwrite) }
      #expect(try await provider.listAll(prefix: "a/b").map(\.key.rawValue) == ["a/b/c", "a/b2"])
      #expect(try await provider.listAll(prefix: "a/b/").map(\.key.rawValue) == ["a/b/c"])
      #expect(try await provider.listAll(prefix: "a").map(\.key.rawValue) == ["a/b/c", "a/b2", "a/d/e", "ab/x"])
      #expect(try await provider.listAll(prefix: "a/d/e/").isEmpty)
    }
  }

  @Test("should never yield change notices")
  func shouldNeverNotify() async throws {
    try await withTemporaryDirectory { directory in
      let provider = try LocalFolderProvider(root: directory)
      let yielded = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
          var iterator = provider.changeNotices().makeAsyncIterator()
          return await iterator.next() != nil
        }
        group.addTask {
          try? await Task.sleep(for: .milliseconds(100))
          return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
      }
      #expect(!yielded)
    }
  }
}

@Suite("FaultInjectingStorageProvider")
struct FaultInjectingStorageProviderTests {
  private struct Failure: Error {
    let message: String
  }

  private func script(_ provider: FaultInjectingStorageProvider, steps: Int) async throws -> [String] {
    var generator = SeededGenerator(seed: 99)
    var outcomes: [String] = []
    let keys = try (0..<6).map { try key("k/\($0)") }
    for _ in 0..<steps {
      let object = generator.pick(from: keys)
      switch generator.int(in: 0...3) {
      case 0: outcomes.append("put \((try? await provider.put(object, data: generator.data(count: 3), condition: .overwrite)) != nil)")
      case 1: outcomes.append("get \((try? await provider.get(object))?.count ?? -1)")
      case 2: outcomes.append("list \((try? await provider.list(prefix: "", after: nil))?.objects.count ?? -1)")
      default: outcomes.append("delete \((try? await provider.delete([object])) != nil)")
      }
    }
    return outcomes
  }

  @Test("should produce the same fault sequence for the same seed")
  func shouldBeDeterministic() async throws {
    let first = FaultInjectingStorageProvider(wrapping: InMemoryStorageProvider(), seed: 7)
    let second = FaultInjectingStorageProvider(wrapping: InMemoryStorageProvider(), seed: 7)
    let other = FaultInjectingStorageProvider(wrapping: InMemoryStorageProvider(), seed: 8)
    let firstOutcomes = try await script(first, steps: 300)
    #expect(firstOutcomes == (try await script(second, steps: 300)))
    _ = try await script(other, steps: 300)
    #expect(!first.faultLog.isEmpty)
    #expect(first.faultLog == second.faultLog)
    #expect(first.faultLog != other.faultLog)
  }

  @Test("should list only objects that were put and return only bytes that were put")
  func shouldNeverInvent() async throws {
    try await forAll(iterations: 40) { generator in
      let provider = FaultInjectingStorageProvider(wrapping: InMemoryStorageProvider(), seed: generator.next())
      let keys = try (0..<8).map { try key("p/\($0)") }
      var history: [ObjectKey: [Data]] = [:]
      for _ in 0..<120 {
        let object = generator.pick(from: keys)
        switch generator.int(in: 0...3) {
        case 0:
          let data = generator.data(count: generator.int(in: 0...6))
          history[object, default: []].append(data)
          _ = try? await provider.put(object, data: data, condition: .overwrite)
        case 1:
          try? await provider.delete([object])
        case 2:
          if let data = try? await provider.get(object), !(history[object] ?? []).contains(data) { throw Failure(message: "get returned unknown bytes for \(object)") }
        default:
          guard let listed = try? await provider.listAll(prefix: "") else { continue }
          if let invented = listed.first(where: { history[$0.key] == nil }) { throw Failure(message: "listed \(invented.key) which was never put") }
          if listed.map(\.key) != listed.map(\.key).sorted() { throw Failure(message: "listing out of order") }
        }
      }
    }
  }

  @Test("should store an object whose acknowledgement was lost")
  func shouldKeepLostAcknowledgements() async throws {
    let inner = InMemoryStorageProvider()
    let provider = FaultInjectingStorageProvider(wrapping: inner, seed: 1, plan: FaultPlan(lostAcknowledgement: 1))
    let object = try key("lost")
    await #expect(throws: StorageError.self) { try await provider.put(object, data: Data([9]), condition: .overwrite) }
    #expect(try await inner.get(object) == Data([9]))
    #expect(provider.faultLog == [.lostAcknowledgement(object)])
  }

  @Test("should fail before applying a transient failure")
  func shouldFailBeforeApplying() async throws {
    let inner = InMemoryStorageProvider()
    let provider = FaultInjectingStorageProvider(wrapping: inner, seed: 1, plan: FaultPlan(transientFailure: 1))
    await #expect(throws: StorageError.self) { try await provider.put(try key("a"), data: Data([9]), condition: .overwrite) }
    #expect(inner.callCounts.put == 0)
  }

  @Test("should restore the full view when healed")
  func shouldHeal() async throws {
    let inner = InMemoryStorageProvider()
    let plan = FaultPlan(staleListing: 1, delayedDelete: 1, staleOperations: 1_000...1_000)
    let provider = FaultInjectingStorageProvider(wrapping: inner, seed: 3, plan: plan)
    let keys = try (0..<5).map { try key("h/\($0)") }
    for object in keys { _ = try await provider.put(object, data: Data([1]), condition: .overwrite) }
    #expect(try await provider.listAll(prefix: "").isEmpty)
    provider.heal()
    #expect(try await provider.listAll(prefix: "").map(\.key) == keys)

    try await provider.delete([keys[0]])
    #expect(try await provider.listAll(prefix: "").map(\.key).contains(keys[0]))
    #expect(try await provider.get(keys[0]) == Data([1]))
    provider.heal()
    #expect(try await provider.listAll(prefix: "").map(\.key) == Array(keys.dropFirst()))
    await #expect(throws: StorageError.notFound(keys[0])) { try await provider.get(keys[0]) }
  }

  @Test("should keep an existing object listed when it is overwritten")
  func shouldNotHideOverwrittenObjects() async throws {
    let plan = FaultPlan(staleListing: 1, staleOperations: 1_000...1_000)
    let provider = FaultInjectingStorageProvider(wrapping: InMemoryStorageProvider(), seed: 4, plan: plan)
    let object = try key("manifest")
    _ = try await provider.put(object, data: Data([1]), condition: .overwrite)
    provider.heal()
    _ = try await provider.put(object, data: Data([2, 2]), condition: .overwrite)
    for _ in 0..<10 { #expect(try await provider.listAll(prefix: "").map(\.key) == [object]) }
  }

  @Test("should satisfy the conformance suite with all faults off")
  func shouldConformWithFaultsOff() async throws {
    try await StorageProviderConformance.verify {
      let provider = FaultInjectingStorageProvider(wrapping: InMemoryStorageProvider(), seed: 5, plan: .hostile)
      provider.setFaultsEnabled(false)
      return provider
    }
  }

  @Test("should satisfy the eventual conformance suite under stale, partial and delayed faults")
  func shouldConformEventually() async throws {
    let plan = FaultPlan(staleListing: 0.7, partialPage: 0.7, delayedDelete: 0.7)
    try await StorageProviderConformance.verify(consistency: .eventual) {
      FaultInjectingStorageProvider(wrapping: InMemoryStorageProvider(), seed: 11, plan: plan)
    }
  }

  @Test("should fail the strong conformance suite when listings are stale")
  func shouldDetectStaleListings() async throws {
    let plan = FaultPlan(staleListing: 1, staleOperations: 1_000...1_000)
    await #expect(throws: StorageConformanceViolation.self) {
      try await StorageProviderConformance.verify { FaultInjectingStorageProvider(wrapping: InMemoryStorageProvider(), seed: 2, plan: plan) }
    }
  }
}

private struct BrokenStorageProvider: StorageProvider {
  enum Flaw {
    case descendingOrder
    case repeatsObjectAcrossPages
    case ifAbsentNeverConflicts
    case missingGetReturnsEmpty
  }

  let inner = InMemoryStorageProvider()
  let flaw: Flaw

  var capabilities: StorageCapabilities { inner.capabilities }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    switch flaw {
    case .descendingOrder:
      let page = try await inner.list(prefix: prefix, after: cursor)
      return ListPage(objects: page.objects.reversed(), next: page.next)
    case .repeatsObjectAcrossPages:
      let all = try await inner.listAll(prefix: prefix).filter { cursor == nil || $0.key.rawValue >= cursor?.token ?? "" }
      let objects = Array(all.prefix(40))
      return ListPage(objects: objects, next: all.count > 40 ? objects.last.map { ListCursor(token: $0.key.rawValue) } : nil)
    default:
      return try await inner.list(prefix: prefix, after: cursor)
    }
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    do {
      return try await inner.get(key)
    } catch {
      guard flaw == .missingGetReturnsEmpty, case .notFound = error else { throw error }
      return Data()
    }
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    try await inner.put(key, data: data, condition: flaw == .ifAbsentNeverConflicts ? .overwrite : condition)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}

@Suite("StorageProviderConformance")
struct StorageProviderConformanceTests {
  private func violatedRule(_ flaw: BrokenStorageProvider.Flaw) async throws -> String? {
    do {
      try await StorageProviderConformance.verify { BrokenStorageProvider(flaw: flaw) }
      return nil
    } catch let violation as StorageConformanceViolation {
      return violation.rule
    }
  }

  @Test("should reject a provider that lists in the wrong order")
  func shouldRejectWrongOrder() async throws {
    #expect(try await violatedRule(.descendingOrder) == "a listing is ascending and returns each object at most once")
  }

  @Test("should reject a provider that returns an object on two pages")
  func shouldRejectRepeatedObjects() async throws {
    #expect(try await violatedRule(.repeatsObjectAcrossPages) == "a listing is ascending and returns each object at most once")
  }

  @Test("should reject an ifAbsent that never throws alreadyExists")
  func shouldRejectUnconditionalIfAbsent() async throws {
    #expect(try await violatedRule(.ifAbsentNeverConflicts) == "an ifAbsent put throws alreadyExists when the key exists")
  }

  @Test("should reject a get of a missing key that returns data")
  func shouldRejectMissingGetReturningData() async throws {
    #expect(try await violatedRule(.missingGetReturnsEmpty) == "get of a missing key throws notFound")
  }
}
