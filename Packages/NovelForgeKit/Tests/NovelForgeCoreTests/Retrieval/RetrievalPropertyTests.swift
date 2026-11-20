import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private enum EntityLife {
  case live
  case removed
}

/// Random edits to one novel's corpus, with catch-ups at random points between them.
private struct EditScript {
  private static let words = ["tide", "lamp", "harbour", "café", "物語", "ash", "bell", "wolf", "ridge", "salt"]

  var generator: SeededGenerator
  var finals = Set<Int>()
  var entities: [String: EntityLife] = [:]

  mutating func text() -> String {
    let paragraphs = generator.int(in: 0...(generator.chance(0.2) ? 60 : 4))
    return (0..<paragraphs).map { _ in
      (0..<generator.int(in: 1...12)).map { _ in generator.pick(from: Self.words) }.joined(separator: " ") + ". "
    }.joined(separator: "\n\n")
  }

  mutating func step(in world: RetrievalWorld) async throws {
    switch generator.int(in: 0...6) {
    case 0:
      let chapter = generator.int(in: 1...6)
      if finals.insert(chapter).inserted { try await world.finalize(chapter, text(), isolated: generator.chance(0.3)) }
    case 1:
      if let chapter = finals.sorted().first(where: { _ in generator.chance(0.5) }) { try await world.amend(chapter, text()) }
    case 2:
      let key = "e\(generator.int(in: 0...4))"
      if entities[key] == nil {
        entities[key] = .live
        try await world.entity(key, name: generator.chance(0.2) ? "" : key, notes: generator.chance(0.5) ? text() : nil)
      }
    case 3:
      if let key = entities.filter({ $0.value == .live }).keys.sorted().first(where: { _ in generator.chance(0.5) }) {
        var edit = EntityEdit()
        edit.body = .set(generator.chance(0.3) ? nil : text())
        try await world.editEntity(key, edit)
      }
    case 4:
      if let key = entities.filter({ $0.value == .live }).keys.sorted().first(where: { _ in generator.chance(0.4) }) {
        entities[key] = .removed
        try await world.removeEntity(key)
      }
    case 5:
      let slug = generator.pick(from: ["harbour", "tower", "timeline"])
      try await world.page(slug == "timeline" ? .project : .world, slug, generator.chance(0.2) ? nil : text())
    default:
      try await world.draft(generator.int(in: 1...6), isolated: generator.chance(0.5))
    }
  }
}

@Suite("Retrieval index properties", TestTimeLimit.property)
struct RetrievalPropertyTests {
  @Test(arguments: 0..<24)
  func shouldEqualAnIndexBuiltFromScratchAfterAnySequenceOfEditsAndCatchUps(_ seed: Int) async throws {
    let world = try RetrievalWorld()
    var script = EditScript(generator: SeededGenerator(seed: UInt64(seed) &* 0x9E37_79B9 &+ 17))
    for _ in 0..<30 {
      try await script.step(in: world)
      if script.generator.chance(0.35) { try await world.retrieval.catchUp(novel: world.novel) }
    }
    try await world.retrieval.catchUp(novel: world.novel)
    let incremental = try await world.dump()
    let searches = try await ["tide", "café cafe", "物語", "wolf ridge"].asyncMap { query in
      try await world.retrieval.searchProseAndLore(novel: world.novel, query: query)
    }
    try await world.checkSearchIntegrity()

    try await world.store.forgetLocalState(novel: world.novel)
    try await world.retrieval.catchUp(novel: world.novel)
    #expect(try await world.dump() == incremental)
    let rebuilt = try await ["tide", "café cafe", "物語", "wolf ridge"].asyncMap { query in
      try await world.retrieval.searchProseAndLore(novel: world.novel, query: query)
    }
    #expect(rebuilt == searches)
    #expect(try await world.retrieval.catchUp(novel: world.novel).isEmpty)
  }
}

extension Array {
  fileprivate func asyncMap<Mapped>(_ transform: (Element) async throws -> Mapped) async rethrows -> [Mapped] {
    var mapped: [Mapped] = []
    for element in self { mapped.append(try await transform(element)) }
    return mapped
  }
}
