import Foundation
import NaturalLanguage
import Synchronization
import Testing

@testable import NovelForgeCore

@Suite("NaturalLanguage sentence embedder", TestTimeLimit.quick)
struct NLSentenceEmbedderTests {
  private static let hasEnglish = NLEmbedding.sentenceEmbedding(for: .english) != nil

  @Test func shouldEmbedALongTextFromItsHeadCutAtAWordBoundary() {
    let short = "The heron stood in the reeds."
    #expect(NLSentenceEmbedder.input(short) == short)
    let long = String(repeating: "heron ", count: 1000)
    let input = NLSentenceEmbedder.input(long)
    #expect(input.count <= NLSentenceEmbedder.maximumInputLength)
    #expect(input.hasSuffix("heron"))
    let unbroken = String(repeating: "x", count: NLSentenceEmbedder.maximumInputLength + 10)
    #expect(NLSentenceEmbedder.input(unbroken).count == NLSentenceEmbedder.maximumInputLength)
  }

  @Test func shouldReadTheNovelsLanguageFromItsSample() {
    #expect(NLSentenceEmbedders.language(of: "Il était une fois un roi qui vivait dans un grand château au bord de la mer.") == .french)
    #expect(NLSentenceEmbedders.language(of: "") == nil)
    #expect(NLSentenceEmbedders.language(of: "12 34 !!") == nil)
  }

  @Test func shouldLetAQueryWaitAtMostOneTextOfARunningBatch() async throws {
    let order = CallOrder()
    let embedder = NLSentenceEmbedder(language: .english, revision: 1, dimension: 2) { text in
      order.append(text)
      usleep(40_000)
      return [1, 0]
    }
    let batch = Task { await embedder.embed((0..<10).map { "text \($0)" }) }
    while order.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
    let started = order.texts.count
    #expect(await embedder.embed(["query"]) == [[1, 0]])
    let position = try #require(order.texts.firstIndex(of: "query"))
    #expect(position - started <= 1, "\(order.texts)")
    #expect(await batch.value.count == 10)
  }

  @Test(.enabled(if: hasEnglish))
  func shouldResolveAStoredIdentityOnlyWhileTheSystemsModelIsStillThatOne() async throws {
    let embedders = NLSentenceEmbedders()
    let current = try #require(await embedders.embedder(forSample: "The heron stood in the reeds while the tide went out over the flats."))
    #expect(await embedders.embedder(forModel: current.model)?.model == current.model)
    let revised = current.model.replacingOccurrences(of: "/r", with: "/r9")
    #expect(await embedders.embedder(forModel: revised) == nil)
    let wider = current.model.replacingOccurrences(of: "/d\(current.dimension)", with: "/d\(current.dimension + 1)")
    #expect(await embedders.embedder(forModel: wider) == nil)
    let recipe = current.model.replacingOccurrences(of: "/i\(NLSentenceEmbedder.inputRecipe)", with: "/i\(NLSentenceEmbedder.inputRecipe + 1)")
    #expect(await embedders.embedder(forModel: recipe) == nil)
    #expect(await embedders.embedder(forModel: "fake/a") == nil)
  }

  @Test(.enabled(if: hasEnglish))
  func shouldNameTheModelByLanguageRevisionAndDimensionAndEmbedConcurrentCallsOneAtATime() async throws {
    let embedder = try #require(NLSentenceEmbedder(language: .english))
    #expect(embedder.model.contains("/en/r") && embedder.model.hasSuffix("/d\(embedder.dimension)/i\(NLSentenceEmbedder.inputRecipe)"))
    let vectors = await withTaskGroup(of: [[Float]?].self) { group in
      for index in 0..<8 { group.addTask { await embedder.embed(["Sentence \(index) about the river.", "   "]) } }
      return await group.reduce(into: []) { $0 += $1 }
    }
    #expect(vectors.count == 16)
    #expect(vectors.filter { $0 == nil }.count == 8)
    #expect(vectors.compactMap(\.self).allSatisfy { $0.count == embedder.dimension })
  }

  @Test(.enabled(if: hasEnglish))
  func shouldFindTheRightChapterForAQueryThatSharesNoWordWithIt() async throws {
    let store = try NovelForgeStore.openInMemory()
    let world = try RetrievalWorld(store: store)
    try await world.finalize(1, "The ship went down in the storm and every sailor drowned in the cold waves.")
    try await world.finalize(2, "She kneaded the dough at dawn and pulled warm loaves from the oven for the market.")
    try await world.finalize(3, "The bride and groom exchanged rings beneath the old oak while the guests cheered.")
    try await world.finalize(4, "The general marched his army across the frozen pass to besiege the fortress.")
    try await world.finalize(5, "He spent the afternoon in the library reading dusty volumes about astronomy.")
    let retrieval = NovelRetrieval(store: store, embedders: NLSentenceEmbedders())
    try await retrieval.catchUp(novel: world.novel)
    #expect(try await retrieval.searchProse(novel: world.novel, query: "soldiers attacking castle").isEmpty)

    let pass = try await retrieval.embedPending(novel: world.novel)
    #expect(pass.embedded == 5 && pass.isComplete)
    #expect(pass.model?.contains("/en/") == true)
    #expect(try await retrieval.searchProse(novel: world.novel, query: "soldiers attacking castle", k: 1).map(\.origin) == [.prose(chapter: 4)])
    #expect(try await retrieval.searchProse(novel: world.novel, query: "baking bread", k: 1).map(\.origin) == [.prose(chapter: 2)])
  }
}

private final class CallOrder: Sendable {
  private let calls = Mutex<[String]>([])

  var texts: [String] { calls.withLock(\.self) }
  var isEmpty: Bool { calls.withLock(\.isEmpty) }

  func append(_ text: String) {
    calls.withLock { $0.append(text) }
  }
}
