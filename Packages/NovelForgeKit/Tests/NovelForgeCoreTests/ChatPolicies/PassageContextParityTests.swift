import ShadowText
import Testing

@testable import NovelForgeCore

struct PassageContextParityTests {
  private static let fixture = Result { try PassageFixture.load() }

  @Test func shouldRelocateEveryQuoteAsTheReference() throws {
    var found = 0
    for (position, item) in try Self.fixture.get().relocations.enumerated() {
      let span = relocateQuote(item.body.value, input: item.input.input, earlierBody: item.earlier?.value)
      #expect(span?.start == item.expected?.start && span?.end == item.expected?.end, "relocation \(position)")
      if span != nil { found += 1 }
    }
    #expect(found > 0)
  }

  @Test func shouldResolveEveryPassageAsTheReference() throws {
    var kinds = Set<String>()
    for (position, item) in try Self.fixture.get().resolves.enumerated() where item.unrepresentable != true {
      let snapshots = item.revisions
      do {
        let resolved = try resolvePassageContexts(
          item.inputs.map(\.input), drafts: item.drafts.map(\.draft), snapshot: { id, revision in snapshots.first { $0.draftId.jsEquals(id) && $0.revision == revision }?.body })
        let expected = try #require(item.expected.contexts, "case \(position) expected a refusal")
        #expect(resolved.count == expected.count && zip(resolved, expected).allSatisfy { sameContext($0, $1.context) }, "case \(position)")
        kinds.insert("ok")
      } catch let error as PassageContextError {
        #expect(error.code == item.expected.error && error.chapter == item.expected.chapter, "case \(position): \(error)")
        kinds.insert(error.code)
      }
    }
    #expect(kinds == ["ok", "CHT_009", "CHT_010", "CHT_011"])
  }

  @Test func shouldListEveryCaseThatCarriesHalfASurrogateInItsComment() throws {
    let skipped = try Self.fixture.get().resolves.filter { $0.unrepresentable == true }
    #expect(!skipped.isEmpty)
    #expect(skipped.allSatisfy { $0.expected.error == "CHT_010" })
  }

  @Test func shouldRenderEveryTurnAsTheReference() throws {
    for (position, item) in try Self.fixture.get().render.enumerated() {
      let contexts = item.contexts?.map(\.context)
      #expect(renderTurnContent(item.content.value, contexts: contexts).jsEquals(item.rendered.value), "render \(position)")
      #expect(authorWords(item.content.value, contexts: contexts).jsEquals(item.authorWords.value), "authorWords \(position)")
      let screens = turnScreens(item.content.value, contexts: contexts)
      #expect(screens.count == item.screens.count, "screens \(position)")
      for (screen, expected) in zip(screens, item.screens) {
        #expect(
          screen.text.jsEquals(expected.text.value) && screen.scope.rawValue == expected.scope && screen.source.jsEquals(expected.source) && screen.sourceRefs == nil,
          "screen \(position)")
      }
    }
  }
}
