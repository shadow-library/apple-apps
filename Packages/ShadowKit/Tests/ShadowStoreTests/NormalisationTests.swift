import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

private let composed = "\u{E9}"
private let decomposed = "e\u{301}"
private let noteRef = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))
private let draftRef = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))

private func title(_ value: String, _ clock: HLCTimestamp) -> ChangeRecord {
  Fixture.change(.set, Fixture.note, noteRef.key, clock: clock, fields: ["title": .string(value)])
}

private func titleBytes(_ state: VaultState) -> [UInt8]? {
  guard case .record(let note) = state.state(of: noteRef), let text = note[field: "title"]?.value.stringValue else { return nil }
  return Array(text.utf8)
}

@Suite("Unicode normalisation")
struct NormalisationTests {
  @Test("should treat the two spellings as equal Swift strings, which is why merge compares bytes")
  func shouldDocumentSwiftEquivalence() {
    #expect(composed == decomposed)
    #expect(!composed.utf8.elementsEqual(decomposed.utf8))
    #expect(ExactString(composed) != ExactString(decomposed))
  }

  @Test("should keep register values that differ only by normalisation distinct in state, digest and round trip")
  func shouldKeepRegisterValuesDistinct() throws {
    let first = Fixture.state([title(composed, Fixture.clock(1))])
    let second = Fixture.state([title(decomposed, Fixture.clock(1))])
    #expect(first != second)
    #expect(first.digest != second.digest)
    #expect(titleBytes(try VaultState(decodingLines: first.encodedLines())) == Array(composed.utf8))
    #expect(titleBytes(try VaultState(decodingLines: second.encodedLines())) == Array(decomposed.utf8))
  }

  @Test("should break an equal-clock tie between the spellings by bytes in every order")
  func shouldBreakTieByBytes() throws {
    let changes = [title(composed, Fixture.clock(1)), title(decomposed, Fixture.clock(1))]
    let winner = [Array(composed.utf8), Array(decomposed.utf8)].max { $0.lexicographicallyPrecedes($1) }
    #expect(titleBytes(Fixture.state(changes)) == winner)
    #expect(titleBytes(Fixture.state(changes.reversed())) == winner)
    #expect(Fixture.state(changes) == Fixture.state(changes.reversed()))
    #expect(Fixture.state(changes).digest == Fixture.state(changes.reversed()).digest)
  }

  @Test("should derive different revision ids for bodies that differ only by normalisation")
  func shouldKeepRevisionsDistinct() throws {
    let items = [composed, decomposed].map { RevisionItem(parent: nil, body: .string($0), created: Fixture.clock(1), generation: 0) }
    #expect(items[0].id != items[1].id)
    let state = Fixture.state(items.map { Fixture.revise($0, clock: Fixture.clock(1), key: draftRef.key, head: false) })
    guard case .revisioned(let draft) = state.state(of: draftRef) else { throw NormalisationFailure.notRevisioned }
    #expect(draft.revisions.count == 2)
    let decoded = try VaultState(decodingLines: state.encodedLines())
    #expect(decoded == state)
    #expect(decoded.digest == state.digest)
    #expect(Fixture.rebuilt(state).digest == state.digest)
  }

  @Test("should keep foreign records that differ only by normalisation apart")
  func shouldKeepForeignRecordsDistinct() throws {
    let id = UUID()
    let records = [composed, decomposed].map { Fixture.change(.set, Fixture.tag, Fixture.key("t1"), clock: Fixture.clock(1), fields: ["label": .string($0)], id: id) }
    let state = Fixture.state(records)
    #expect(state.foreign.count == 2)
    #expect(try VaultState(decodingLines: state.encodedLines()).foreign.map { $0.canonicalBytes() } == state.foreign.map { $0.canonicalBytes() })
  }

  @Test("should keep normalisation variants apart on random histories")
  func shouldKeepVariantsApartOnRandomHistories() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      let changes = factory.changes(&generator, count: 0...20)
      let (spelling, other) = generator.chance(0.5) ? (composed, decomposed) : (decomposed, composed)
      let clock = Fixture.clock(9, 9)
      let left = Fixture.state(changes + [title(spelling, clock)])
      let right = Fixture.state(changes + [title(other, clock)])
      guard case .record = left.state(of: noteRef) else { return }
      try #require(left != right)
      try #require(left.digest != right.digest)
      try #require(try VaultState(decodingLines: left.encodedLines()).digest == left.digest)
    }
  }
}

private enum NormalisationFailure: Error {
  case notRevisioned
}
