import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private let settings = SyncConfiguration(
  maximumSegmentLines: 100, compactionAge: SyncDays.duration(15), compactionBytes: .max, compactionFiles: .max, compactionInterval: .zero)

private func greedy(_ sizes: [Int], limit: Int) -> [Int] {
  var counts: [Int] = []
  var count = 0
  var bytes = 0
  for size in sizes {
    if count > 0, bytes + size > limit {
      counts.append(count)
      (count, bytes) = (0, 0)
    }
    count += 1
    bytes += size
  }
  return count > 0 ? counts + [count] : counts
}

private func send(_ harness: SyncHarness, _ count: Int, _ prefix: String) async throws -> StreamPoint {
  try await harness.writeNotes(count, prefix: prefix)
  return try #require(try await harness.uploaded().last)
}

@Suite("SyncEngine reader bookkeeping")
struct SyncEngineBookkeepingTests {
  @Test("should forget applied files only when they are unlisted and covered, keep the highest base, and apply a file again when it reappears")
  func shouldPruneCoveredUnlistedRows() async throws {
    let world = SyncCompactWorld()
    let writer = try await world.started(world.harness("writer", store: try world.openStore(), configuration: settings), createsKey: true)
    let readerProvider = SyncCompactProvider(wrapping: world.storage)
    let reader = try await world.started(world.harness("reader", store: try world.openStore(), provider: readerProvider, configuration: settings))
    let first = try await send(writer, 2, "a")
    let second = try await send(writer, 2, "b")
    try await SyncCompactCheck.drain(reader)
    let firstKey = try #require(try await writer.segments(of: writer.store.replica).first { $0.point == first })
    world.advance(days: 20)
    let young = try await send(writer, 2, "c")
    guard case .compacted(let base, 2, 0) = try await writer.engine.compact(force: true) else { throw SyncFixtureFailure("expected a base") }
    let after = try await send(writer, 1, "d")

    try await SyncCompactCheck.drain(reader)

    let applied = try #require(try await reader.appliedFiles()[writer.store.replica])
    #expect(applied.bases == [base])
    #expect(applied.segments == [young, after])
    #expect(!applied.segments.contains(first) && !applied.segments.contains(second))

    world.advance(days: 20)
    let latest = try await send(writer, 1, "e")
    guard case .compacted(let newer, 2, 1) = try await writer.engine.compact(force: true) else { throw SyncFixtureFailure("expected a newer base") }
    try await SyncCompactCheck.drain(reader)
    #expect(try await reader.appliedFiles()[writer.store.replica]?.bases == [newer])
    #expect(try await reader.appliedFiles()[writer.store.replica]?.segments == [latest])

    readerProvider.hide(VaultPath.basePrefix(writer.store.replica))
    try await SyncCompactCheck.drain(reader)
    #expect(try await reader.appliedFiles()[writer.store.replica]?.bases == [newer])
    readerProvider.reveal()

    let digest = try await reader.digest()
    _ = try await world.storage.put(firstKey.key, data: firstKey.data, condition: .overwrite)
    let reapplied = try await SyncCompactCheck.drain(reader)
    #expect(reapplied == [SyncFileID(replica: writer.store.replica, kind: .segment, point: first)])
    #expect(try await reader.digest() == digest)
  }

  @Test("should fetch an unavailable file on each of its first failing calls and then on every eighth, and start again when its size changes")
  func shouldBackOffUnavailableFile() async throws {
    let inner = InMemoryStorageProvider()
    let hiding = SyncHidingProvider(wrapping: inner)
    let peers = try await SyncPeers.make(2, provider: hiding)
    let (a, b) = (peers[0], peers[1])
    try await a.writeNotes(1)
    let fromA = a.segmentIDs(try await a.uploaded())
    let stored = try #require(try await a.segments(of: a.store.replica).first)
    hiding.fail(stored.key, with: .underlying("checksum mismatch"))
    let before = hiding.gets(of: stored.key)

    var fetched: [Int] = []
    for call in 0..<20 {
      let gets = hiding.gets(of: stored.key)
      #expect(try await b.engine.download().held == [fromA[0]: .unavailable])
      if hiding.gets(of: stored.key) > gets { fetched.append(call) }
    }

    #expect(fetched == [0, 1, 2, 10, 18])
    #expect(fetched == (0..<20).filter { SyncDownloadSession.isRetryDue(afterUnavailableCalls: $0) })
    #expect(hiding.gets(of: stored.key) == before + 5)
    _ = try await inner.put(stored.key, data: stored.data + Data([0]), condition: .overwrite)
    var resized: [Int] = []
    for call in 0..<4 {
      let gets = hiding.gets(of: stored.key)
      _ = try await b.engine.download()
      if hiding.gets(of: stored.key) > gets { resized.append(call) }
    }
    #expect(resized == [0, 1, 2])
    _ = try await inner.put(stored.key, data: stored.data, condition: .overwrite)
    hiding.fail(stored.key, with: nil)
    for _ in 0..<7 { _ = try await b.engine.download() }
    #expect(try await b.appliedFiles()[a.store.replica]?.segments == [fromA[0].point])
    #expect(try await b.heldFiles().isEmpty)
  }
}

@Suite("SyncEngine strict upload passes")
struct SyncEngineStrictPassTests {
  @Test("should keep the change lines of every pass within the byte budget")
  func shouldKeepPassesWithinBudget() async throws {
    let budget = 900
    let configuration = SyncConfiguration(maximumSegmentBytes: 1 << 20, maximumSegmentLines: 10_000, uploadPassBytes: budget)
    let harness = try await SyncHarness.started(configuration: configuration)
    try await harness.writeNotes(30) { "title \($0) \(String(repeating: "x", count: 60))" }
    let sizes = try await harness.pendingLines().map(\.count)
    #expect(sizes.reduce(0, +) > 4 * budget)

    _ = try await harness.uploaded()

    let segments = try await harness.segments()
    #expect(segments.count > 4)
    #expect(segments.allSatisfy { $0.file.lines.map(\.count).reduce(0, +) <= budget })
    #expect(segments.map(\.file.lines.count) == greedy(sizes, limit: budget))
    #expect(try await harness.pendingLines().isEmpty)
    try SyncChain.verify(segments, count: Int64(sizes.count), history: try await harness.history())
  }
}
