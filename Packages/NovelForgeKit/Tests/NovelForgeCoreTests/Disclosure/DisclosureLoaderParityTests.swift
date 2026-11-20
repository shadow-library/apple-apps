import ShadowText
import Testing

@testable import NovelForgeCore

private func keys(_ facts: [DisclosureFact]) -> [String] {
  facts.map(\.factKey)
}

private func optionalString(_ text: String?) -> OrderedJSON {
  text.map(OrderedJSON.string) ?? .null
}

private func optionalInt(_ number: Int?) -> OrderedJSON {
  number.map { .int(Int64($0)) } ?? .null
}

private func sourcesRow(_ sources: WriterDisclosureSources) -> OrderedJSON {
  .array([
    .array(keys(sources.lockedFacts).map(OrderedJSON.string)), optionalString(sources.ending), optionalString(sources.endingQuestion),
    .array(sources.laterVolumes.map { .array([.string($0.volumeKey), optionalString($0.title), optionalString($0.objective), optionalString($0.body)]) }),
    .array(sources.plannerPages.map { .array([.string($0.address.section), .string($0.address.slug)]) }),
    .array(
      sources.volumeOrdinals.map { .array([.string($0.key.value), .int(Int64($0.value))]) }.sorted {
        ($0.at(0).stringValue ?? "").unicodeScalars.lexicographicallyPrecedes(($1.at(0).stringValue ?? "").unicodeScalars)
      }),
    optionalInt(sources.currentVolumeOrdinal),
  ])
}

private func sortedOrdinals(_ row: OrderedJSON) -> OrderedJSON {
  .array(row.items.sorted { ($0.at(0).stringValue ?? "").unicodeScalars.lexicographicallyPrecedes(($1.at(0).stringValue ?? "").unicodeScalars) })
}

private func viewRow(_ view: KnowledgeView) -> OrderedJSON {
  let list = { (facts: [DisclosureFact]) in OrderedJSON.array(keys(facts).map(OrderedJSON.string)) }
  return .array([
    list(view.known), list(view.reveals), list(view.hidden), list(view.readerKnows), .array(view.pooledPov.map { .array([.string($0.entityKey), .string($0.name)]) }),
    view.learnedIn.map { .array($0.map { .array([.string($0.factKey), .int(Int64($0.chapter))]) }) } ?? .null,
  ])
}

@Suite("Disclosure loaders, over in-memory inputs, against the reference loaders")
struct DisclosureLoaderParityTests {
  @Test("should derive the knowledge view, the hidden and forbidden facts and the policy's sources as the reference reads them")
  func shouldMatchLoaders() throws {
    let cases = try DisclosureFixture.cases("view.json", "viewCases")
    #expect(cases.count > 50)
    var endingWithheldOnlyHere = 0
    for row in cases {
      for query in row.at(1).items {
        let chapter = try #require(query.at(0).intValue)
        let world = fixtureWorld(row.at(0), readerKnowsLabel: query.at(1).bool)
        let overlay = query.at(2) == .null ? nil : fixturePlan(query.at(2))
        let label = "chapter \(chapter) of \(row.at(0).at(0).items.map { $0.at(0).stringValue ?? "" })"

        let contract = parseKnowledgeContract(query.at(3).tagged)
        let readerKnows: Bool? = query.at(4) == .null ? nil : query.at(4).bool
        let view = contract.map { knowledgeView(in: world, chapter: chapter, contract: $0, readerKnows: readerKnows, overlay: overlay) }
        #expect((view.map(viewRow) ?? .null) == query.at(5), "view at \(label)")

        let hidden = writerHiddenFactKeys(in: world, chapter: chapter, facts: world.facts, overlay: overlay).map(\.value)
        #expect(codePointSorted(hidden) == codePointSorted(query.at(6).strings ?? []), "hidden at \(label)")
        #expect(sameTexts(keys(writerForbiddenFacts(in: world, chapter: chapter, overlay: overlay)), query.at(7).strings ?? []), "forbidden at \(label)")

        let sources = writerDisclosureSources(in: world, chapter: chapter, overlay: overlay)
        var expectedSources = query.at(8).items
        if expectedSources.count == 7 { expectedSources[5] = sortedOrdinals(expectedSources[5]) }
        #expect(sourcesRow(sources) == .array(expectedSources), "sources at \(label)")

        var writer = try writerDisclosurePolicy(sources)
        var art = try artDisclosurePolicy(in: world, chapter: chapter)
        let field = try #require(WriterField(rawValue: query.at(10).stringValue ?? ""))
        for (index, probe) in query.at(9).items.enumerated() {
          let text = probe.stringValue ?? ""
          #expect(OrderedJSON.string(try writer.scrub(text, field)) == query.at(11).at(index), "writer scrub at \(label): \(text.debugDescription)")
          #expect(OrderedJSON.string(try art.scrub(text, field)) == query.at(12).at(index), "art scrub at \(label): \(text.debugDescription)")
        }
        for ref in query.at(13).items {
          #expect(writer.canResolve(ref.at(0).stringValue ?? "") == ref.at(1).bool, "canResolve \(ref.at(0)) at \(label)")
        }

        let notes = factWriterNotes(endingContract: world.storedPlan(for: chapter)?.endingContract, facts: world.facts)
        #expect(OrderedJSON.array(notes.map { .array([.string($0.factKey), optionalString($0.writerNote)]) }) == query.at(14), "notes at \(label)")
        #expect(sameText(nearestVolumeKey(world.plans.map(\.claims), chapter: chapter), query.at(15).stringValue), "nearest volume at \(label)")
        let contexts = [true, false].map { chapterUnlockContext(world.planWorld, chapter: chapter, conditioned: $0, overlay: overlay?.claims) }
        #expect(contexts.map(contextRow) == query.at(16).items, "chapter contexts at \(label)")
        #expect(contextRow(plannedUnlockContexts(world.planWorld, conditioned: true)(chapter)) == query.at(17), "planned context at \(label)")

        let variant = query.at(18)
        if variant != .null {
          #expect(variant.at(0) == .null || sources.ending != nil, "the other ending order withholds the ending at \(label)")
          #expect(variant.at(1) == .null || sources.endingQuestion != nil, "the other ending order withholds the ending question at \(label)")
          if variant.at(0) == .null && sources.ending != nil { endingWithheldOnlyHere += 1 }
        }
      }
    }
    #expect(endingWithheldOnlyHere > 0)
  }
}
