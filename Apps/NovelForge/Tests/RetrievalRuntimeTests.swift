import Foundation
import NovelForgeCore
import ShadowStore
import SwiftUI
import Synchronization
import Testing

@testable import NovelForge

/// One dimension per distinct word; counts every text it embeds.
nonisolated final class CountingEmbedder: Embedder, EmbedderProvider {
  let model = "test/counting"
  let dimension = 32
  private let texts = Mutex(0)

  var embedded: Int { texts.withLock(\.self) }

  func embed(_ texts: [String]) async -> [[Float]?] {
    self.texts.withLock { $0 += texts.count }
    return texts.map { text in
      var vector = [Float](repeating: 0, count: dimension)
      for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) { vector[Int(UInt(bitPattern: word.hashValue) % UInt(dimension))] += 1 }
      return vector
    }
  }

  func embedder(forSample sample: String) async -> (any Embedder)? { self }

  func embedder(forModel model: String) async -> (any Embedder)? { model == self.model ? self : nil }
}

@MainActor
@Suite("Retrieval runtime", TestTimeLimit.standard)
struct RetrievalRuntimeTests {
  nonisolated private static let novel = UUID(uuidString: "6f0c4d1e-0000-4000-8000-0000000000f1") ?? UUID()

  private static func finalize(_ chapter: Int, _ body: String, in store: VaultStore) async throws {
    _ = try await store.write { transaction in
      try FinalChapterRecord(novel: novel, chapter: chapter, canon: Canon(body: body)).finalize(in: &transaction)
    }
  }

  private static func found(_ query: String, in store: VaultStore) async throws -> [Int] {
    try await NovelRetrieval(store: store).searchProse(novel: novel, query: query).compactMap { hit in
      guard case .prose(let chapter) = hit.origin else { return nil }
      return chapter
    }
  }

  private static func running(_ runtimes: RetrievalRuntimes) async -> Bool {
    await runtimes.upkeep?.isRunning == true
  }

  @Test func shouldIndexTheOpenVaultAtLaunchAndKeepItCurrentAfterWrites() async throws {
    let store = try NovelForgeStore.openInMemory()
    try await Self.finalize(1, "The lighthouse keeper climbed the stairs.", in: store)
    let embedder = CountingEmbedder()
    let runtimes = RetrievalRuntimes(debounce: .milliseconds(50))
    await runtimes.launch(store, embedders: embedder)
    try await JobsWait.until("the launch indexes the novel") { try await Self.found("lighthouse", in: store) == [1] && embedder.embedded == 1 }
    try await Self.finalize(2, "A gull watched the harbour.", in: store)
    try await JobsWait.until("the write is indexed") { try await Self.found("harbour", in: store) == [2] && embedder.embedded == 2 }
    #expect(await Self.running(runtimes))
    await runtimes.upkeep?.stop()
  }

  @Test func shouldStopInTheBackgroundAndStartOnReturnWhereThePlatformSuspends() async throws {
    let store = try NovelForgeStore.openInMemory()
    let runtimes = RetrievalRuntimes(stopsInBackground: true)
    await runtimes.launch(store, embedders: CountingEmbedder())
    #expect(await Self.running(runtimes))
    await runtimes.phaseChanged(.inactive)
    #expect(await Self.running(runtimes))
    await runtimes.phaseChanged(.background)
    #expect(await Self.running(runtimes) == false)
    await runtimes.phaseChanged(.inactive)
    #expect(await Self.running(runtimes) == false)
    await runtimes.phaseChanged(.active)
    #expect(await Self.running(runtimes))
    await runtimes.upkeep?.stop()
  }

  @Test func shouldKeepRunningInTheBackgroundOnTheMac() async throws {
    let runtimes = RetrievalRuntimes(stopsInBackground: false)
    await runtimes.launch(try NovelForgeStore.openInMemory(), embedders: CountingEmbedder())
    await runtimes.phaseChanged(.background)
    #expect(await Self.running(runtimes))
    await runtimes.upkeep?.stop()
  }

  @Test func shouldStartAVaultOpenedInTheBackgroundOnlyOnReturn() async throws {
    let runtimes = RetrievalRuntimes(stopsInBackground: true)
    await runtimes.phaseChanged(.background)
    await runtimes.launch(try NovelForgeStore.openInMemory(), embedders: CountingEmbedder())
    #expect(await Self.running(runtimes) == false)
    await runtimes.phaseChanged(.active)
    #expect(await Self.running(runtimes))
    await runtimes.upkeep?.stop()
  }

  @Test func shouldKeepOneUpkeepPerVaultAndStopTheOneItReplaces() async throws {
    let (first, second) = (try NovelForgeStore.openInMemory(), try NovelForgeStore.openInMemory())
    let runtimes = RetrievalRuntimes()
    await runtimes.launch(first, embedders: CountingEmbedder())
    let original = try #require(runtimes.upkeep)
    await runtimes.launch(first, embedders: CountingEmbedder())
    #expect(runtimes.upkeep === original)
    await runtimes.launch(second, embedders: CountingEmbedder())
    #expect(runtimes.upkeep !== original)
    #expect(await original.isRunning == false)
    #expect(await Self.running(runtimes))
    await runtimes.upkeep?.stop()
  }
}
