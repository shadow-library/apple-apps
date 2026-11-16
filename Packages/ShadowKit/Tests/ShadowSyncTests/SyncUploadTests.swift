import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private func randomTitle(_ generator: inout SeededGenerator, bytes: Int) -> String {
  generator.data(count: bytes / 2).map { String(format: "%02x", $0) }.joined()
}

@Suite("SyncEngine upload")
struct SyncUploadTests {
  @Test("should refuse to upload before start has bootstrapped the replica")
  func shouldRefuseBeforeStart() async throws {
    let harness = SyncHarness(store: try SyncFixture.open(), provider: InMemoryStorageProvider())
    let error = await #expect(throws: SyncError.self) { try await harness.engine.upload() }
    guard case .notStarted? = error else { throw SyncFixtureFailure("expected notStarted, got \(String(describing: error))") }
  }

  @Test("should put the pending changes as one segment named by its content and empty the change log")
  func shouldUploadOneSegment() async throws {
    let harness = try await SyncHarness.started()
    try await harness.writeNotes(3)
    let lines = try await harness.pendingLines()
    let replica = harness.store.replica

    let outcome = try await harness.engine.upload()

    let segments = try await harness.segments()
    let segment = try #require(segments.first)
    #expect(segments.count == 1)
    #expect(outcome == .uploaded([segment.point]))
    #expect(segment.key == VaultPath.segment(replica, first: 1, last: Int64(lines.count), tag: segment.point.tag))
    #expect(segment.file.lines == lines)
    let header = segment.file.header
    #expect(header.replica == replica && header.first == 1 && header.last == Int64(lines.count) && header.previous == nil)
    #expect(header.schema == SyncFixture.registry.version && header.dependencies.isEmpty)
    #expect(try await harness.pendingLines().isEmpty)
    #expect(try await harness.history() == ReplicaUploadHistory(segments: [segment.point]))
    #expect(try await harness.savedUpload() == nil)
  }

  @Test("should chain a second batch to the first with contiguous sequences")
  func shouldChainSecondBatch() async throws {
    let harness = try await SyncHarness.started()
    try await harness.writeNotes(2)
    guard case .uploaded(let first) = try await harness.engine.upload() else { throw SyncFixtureFailure("the first batch was not uploaded") }
    try await harness.writeNotes(2, prefix: "m")
    let lines = try await harness.pendingLines()

    guard case .uploaded(let second) = try await harness.engine.upload() else { throw SyncFixtureFailure("the second batch was not uploaded") }

    let segments = try await harness.segments()
    #expect(segments.map(\.point) == first + second)
    let header = try #require(segments.last?.file.header)
    #expect(header.previous == first.last && header.first == (first.last?.last ?? 0) + 1)
    #expect(segments.last?.file.lines == lines)
    try SyncChain.verify(segments, count: header.last, history: try await harness.history())
  }

  @Test("should report nothing to upload when the change log is empty")
  func shouldReportNothingToUpload() async throws {
    let harness = try await SyncHarness.started()
    _ = try await harness.engine.upload()
    #expect(try await harness.engine.upload() == .nothingToUpload)
  }

  @Test("should split many changes into chained segments within the line and byte limits")
  func shouldSplitByLimits() async throws {
    let configuration = SyncConfiguration(maximumSegmentBytes: 700, maximumSegmentLines: 3)
    let harness = try await SyncHarness.started(configuration: configuration)
    var generator = SeededGenerator(seed: 7)
    let titles = (0..<12).map { _ in randomTitle(&generator, bytes: generator.int(in: 10...300)) }
    try await harness.writeNotes(titles.count) { titles[$0] }
    let lines = try await harness.pendingLines()

    guard case .uploaded(let points) = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    let segments = try await harness.segments()
    #expect(points == segments.map(\.point) && segments.count > 4)
    for segment in segments {
      #expect(segment.file.lines.count <= 3)
      #expect(segment.file.lines.count == 1 || segment.file.lines.reduce(0) { $0 + $1.count + 1 } <= 700)
    }
    #expect(segments.flatMap(\.file.lines) == lines)
    try SyncChain.verify(segments, count: Int64(lines.count), history: try await harness.history())
  }

  @Test("should seal smaller segments when the provider limits object size")
  func shouldRespectObjectLimit() async throws {
    let limit = 1_500
    let harness = try await SyncHarness.started(provider: InMemoryStorageProvider(maxObjectBytes: limit))
    var generator = SeededGenerator(seed: 11)
    let titles = (0..<8).map { _ in randomTitle(&generator, bytes: 400) }
    try await harness.writeNotes(titles.count) { titles[$0] }
    let lines = try await harness.pendingLines()

    _ = try await harness.engine.upload()

    let segments = try await harness.segments()
    #expect(segments.count > 1 && segments.allSatisfy { $0.data.count <= limit })
    #expect(segments.flatMap(\.file.lines) == lines)
    try SyncChain.verify(segments, count: Int64(lines.count), history: try await harness.history())
  }

  @Test("should refuse a change that cannot fit in one object and upload nothing")
  func shouldRefuseOversizedChange() async throws {
    let provider = InMemoryStorageProvider(maxObjectBytes: 2_000)
    let harness = try await SyncHarness.started(provider: provider, configuration: SyncConfiguration(maximumSegmentLines: 1))
    var generator = SeededGenerator(seed: 13)
    try await harness.writeNotes(2) { _ in randomTitle(&generator, bytes: 400) }
    let big = randomTitle(&generator, bytes: 6_000)
    try await harness.writeNotes(1, prefix: "big") { _ in big }
    let lines = try await harness.pendingLines()

    let error = await #expect(throws: SyncError.self) { try await harness.engine.upload() }
    guard case .changeTooLarge(let sequence, 2_000)? = error else { throw SyncFixtureFailure("expected changeTooLarge, got \(String(describing: error))") }
    #expect(sequence == Int64(lines.count))

    #expect(provider.callCounts.put == 0)
    #expect(try await harness.pendingLines() == lines)
    #expect(try await harness.savedUpload() == nil)
  }

  @Test("should refuse a change whose sync class the provider may not hold and upload nothing")
  func shouldRefuseSyncClass() async throws {
    let provider = InMemoryStorageProvider(classPolicy: .iCloud)
    let harness = try await SyncHarness.started(provider: provider)
    try await harness.writeNotes(2)
    try await harness.store.write { transaction in
      _ = try transaction.set(EntityRef(kind: SyncFixture.vital, key: ReplicaFixture.key("weight")), ["value": .int(72)])
    }
    let lines = try await harness.pendingLines()

    let error = await #expect(throws: SyncError.self) { try await harness.engine.upload() }
    guard case .syncClassRefused(let kind, .health)? = error else { throw SyncFixtureFailure("expected syncClassRefused, got \(String(describing: error))") }
    #expect(kind == SyncFixture.vital)

    #expect(provider.callCounts.put == 0)
    #expect(try await harness.pendingLines() == lines)
  }

  @Test("should upload health-class changes to a provider without a class restriction")
  func shouldUploadHealthClassWhereAllowed() async throws {
    let harness = try await SyncHarness.started()
    try await harness.store.write { transaction in
      _ = try transaction.set(EntityRef(kind: SyncFixture.vital, key: ReplicaFixture.key("weight")), ["value": .int(72)])
    }
    guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }
    #expect(try await harness.pendingLines().isEmpty)
  }

  @Test("should serialise concurrent uploads so every change is stored once")
  func shouldSerialiseConcurrentUploads() async throws {
    let harness = try await SyncHarness.started()
    try await harness.writeNotes(5)
    let count = Int64(try await harness.pendingLines().count)

    async let first = harness.engine.upload()
    async let second = harness.engine.upload()
    let outcomes = try await [first, second]

    #expect(outcomes.contains(.nothingToUpload))
    try SyncChain.verify(try await harness.segments(), count: count, history: try await harness.history())
  }
}
