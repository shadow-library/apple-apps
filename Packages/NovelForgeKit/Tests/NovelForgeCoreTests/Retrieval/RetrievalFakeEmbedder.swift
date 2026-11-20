import Foundation
import Synchronization

@testable import NovelForgeCore

/// A deterministic embedder: words of one concept share a dimension, so texts with no word in common can still be near; any other word lands on a
/// dimension of its own by a stable hash. `vectors` pins exact texts to exact vectors, and a few marker words make it misbehave on purpose.
actor FakeEmbedder: Embedder {
  static let failing = "zzfail"
  static let zero = "zzzero"
  static let notANumber = "zznan"
  static let short = "zzshort"

  private static let concepts: [[String]] = [
    ["ship", "vessel", "boat", "boats"],
    ["storm", "tempest", "gale"],
    ["bread", "loaf", "loaves", "baker", "oven"],
    ["castle", "fortress", "keep"],
    ["soldier", "soldiers", "army"],
  ]

  nonisolated let model: String
  nonisolated let dimension: Int
  private let vectors: [String: [Float]]
  private let cancelOnCall: Int?
  private(set) var calls: [[String]] = []

  init(model: String = "fake/a", dimension: Int = 16, vectors: [String: [Float]] = [:], cancelOnCall: Int? = nil) {
    self.model = model
    self.dimension = dimension
    self.vectors = vectors
    self.cancelOnCall = cancelOnCall
  }

  var embeddedTexts: [String] { calls.flatMap(\.self) }

  func embed(_ texts: [String]) async -> [[Float]?] {
    calls.append(texts)
    if calls.count == cancelOnCall { withUnsafeCurrentTask { $0?.cancel() } }
    return texts.map(vector)
  }

  private func vector(_ text: String) -> [Float]? {
    if let pinned = vectors[text] { return pinned }
    let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    if words.isEmpty || words.contains(Self.failing) { return nil }
    if words.contains(Self.zero) { return Array(repeating: 0, count: dimension) }
    if words.contains(Self.notANumber) { return [.nan] + Array(repeating: 1, count: dimension - 1) }
    if words.contains(Self.short) { return Array(repeating: 1, count: dimension - 1) }
    var values = [Float](repeating: 0, count: dimension)
    for word in words { values[slot(of: word)] += 1 }
    return values
  }

  private func slot(of word: String) -> Int {
    if let concept = Self.concepts.firstIndex(where: { $0.contains(word) }) { return concept }
    let hash = word.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    return Self.concepts.count + Int(hash % UInt64(dimension - Self.concepts.count))
  }
}

final class FakeEmbedders: EmbedderProvider {
  let embedder: FakeEmbedder?
  private let samples = Mutex(0)

  init(embedder: FakeEmbedder?) {
    self.embedder = embedder
  }

  var sampleRequests: Int { samples.withLock(\.self) }

  func embedder(forSample sample: String) async -> (any Embedder)? {
    samples.withLock { $0 += 1 }
    return embedder
  }

  func embedder(forModel model: String) async -> (any Embedder)? {
    embedder?.model == model ? embedder : nil
  }
}
