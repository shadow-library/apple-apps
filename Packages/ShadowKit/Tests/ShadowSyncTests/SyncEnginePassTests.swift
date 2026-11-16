import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private func greedy(_ sizes: ArraySlice<Int>, limit: Int) -> [Range<Int>] {
  var ranges: [Range<Int>] = []
  var start = sizes.startIndex
  while start < sizes.endIndex {
    var end = start
    var bytes = 0
    while end < sizes.endIndex, end == start || bytes + sizes[end] <= limit {
      bytes += sizes[end]
      end += 1
    }
    ranges.append(start..<end)
    start = end
  }
  return ranges
}

@Suite("SyncEngine upload passes")
struct SyncEnginePassTests {
  @Test("should upload a large backlog in several passes, each within the byte budget, as one valid chain")
  func shouldBoundEachPass() async throws {
    let probe = try await SyncHarness.started()
    try await probe.writeNotes(1) { _ in String(repeating: "x", count: 120) }
    let lineBytes = try #require(try await probe.pendingLines().last).count + 1
    let configuration = SyncConfiguration(maximumSegmentBytes: 3 * lineBytes, maximumSegmentLines: 100, uploadPassBytes: 7 * lineBytes + lineBytes / 2)
    let harness = try await SyncHarness.started(configuration: configuration)
    try await harness.writeNotes(40) { _ in String(repeating: "x", count: 120) }
    let sizes = try await harness.pendingLines().map { $0.count + 1 }

    _ = try await harness.uploaded()

    let passes = greedy(sizes[...], limit: configuration.uploadPassBytes)
    #expect(passes.count > 4)
    #expect(passes.allSatisfy { $0.count == 1 || sizes[$0].reduce(0, +) <= configuration.uploadPassBytes })
    let expected = passes.flatMap { greedy(sizes[$0], limit: configuration.maximumSegmentBytes) }.map(\.count)
    #expect(expected != greedy(sizes[...], limit: configuration.maximumSegmentBytes).map(\.count))
    let segments = try await harness.segments()
    #expect(segments.map(\.file.lines.count) == expected)
    #expect(try await harness.pendingLines().isEmpty)
    try SyncChain.verify(segments, count: Int64(sizes.count), history: try await harness.history())
  }
}
