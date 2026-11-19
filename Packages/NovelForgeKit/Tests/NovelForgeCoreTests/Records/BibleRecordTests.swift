import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private func editCoverage<Field: FieldName>(_: Field.Type, _ build: (Field) -> RecordFields<Field>) {
  for field in Field.allCases { #expect(Set(build(field).members.keys) == [field.rawValue], "\(field.rawValue)") }
}

@Suite("Bible record round trip", TestTimeLimit.standard)
struct BibleRecordTests {
  @Test func shouldCreateAndEditASecretWithoutTouchingOtherFields() async throws { try await createAndEdit(SecretSubject.self, seed: 0xA6) }
  @Test func shouldCreateAndEditAnEntityWithoutTouchingOtherFields() async throws { try await createAndEdit(EntitySubject.self, seed: 0xA7) }
  @Test func shouldCreateAndEditAManualRevealWithoutTouchingOtherFields() async throws { try await createAndEdit(CharacterKnowledgeSubject.self, seed: 0xA8) }

  @Test func shouldRemoveRestoreAndRecreateASecret() async throws { try await removalCycle(SecretSubject.self, seed: 0xB6) }
  @Test func shouldRemoveRestoreAndRecreateAnEntity() async throws { try await removalCycle(EntitySubject.self, seed: 0xB7) }
  @Test func shouldRetractRestoreAndRecreateAManualReveal() async throws { try await removalCycle(CharacterKnowledgeSubject.self, seed: 0xB8) }

  @Test func shouldOverwriteEveryFieldWhenASecretIsCreatedOverALiveOne() async throws { try await createOverLiveRecord(SecretSubject.self, seed: 0xC6) }
  @Test func shouldOverwriteEveryFieldWhenAnEntityIsCreatedOverALiveOne() async throws { try await createOverLiveRecord(EntitySubject.self, seed: 0xC7) }
  @Test func shouldOverwriteEveryFieldWhenAManualRevealIsCreatedOverALiveOne() async throws { try await createOverLiveRecord(CharacterKnowledgeSubject.self, seed: 0xC8) }

  @Test func shouldKeepNewerMembersOfNestedObjectsAcrossAnEditAndARestore() async throws {
    let store = try SchemaFixture.store()
    let secretKey = NovelForgeKey.secretKey(novel: SchemaFixture.novel, secret: "heir")
    var members = SecretRecord(novel: SchemaFixture.novel, secret: "heir", text: "t").storedMembers
    members["clues_and_terms"] = ["clues": ["a ring"], "terms": nil, "weight": 3]
    try await SchemaFixture.set(secretKey.ref, members, in: store)
    var secret = try #require(try await Harness.read(secretKey.ref, as: SecretRecord.self, in: store).entry?.record)
    secret.cluesAndTerms?.clues = ["a ring", "a crest"]
    var edit = SecretEdit()
    edit.cluesAndTerms = .set(secret.cluesAndTerms)
    let change = try await store.write { [edit] transaction in try SecretRecord.edit(novel: SchemaFixture.novel, secret: "heir", edit, in: &transaction) }
    #expect(change.fields["clues_and_terms"] == ["clues": ["a ring", "a crest"], "terms": nil, "weight": 3])
    _ = try await Harness.restore(secret, in: store)
    #expect(try await SchemaFixture.record(secretKey.ref, in: store)[field: "clues_and_terms"]?.value == ["clues": ["a ring", "a crest"], "terms": nil, "weight": 3])

    let revealKey = NovelForgeKey.characterKnowledgeKey(novel: SchemaFixture.novel, fact: "heir", entity: "aria")
    try await SchemaFixture.set(
      revealKey.ref, ["natural_key": revealKey.stored, "removed": false, "reveal": ["chapter": 5, "note": nil, "source_device": "x"]], in: store)
    var reveal = try #require(try await Harness.read(revealKey.ref, as: CharacterKnowledgeRecord.self, in: store).entry?.record)
    reveal.reveal.chapter = 6
    var revealEdit = CharacterKnowledgeEdit()
    revealEdit.reveal = .set(reveal.reveal)
    let revealChange = try await store.write { [revealEdit] transaction in
      try CharacterKnowledgeRecord.edit(novel: SchemaFixture.novel, fact: "heir", entity: "aria", revealEdit, in: &transaction)
    }
    #expect(revealChange.fields["reveal"] == ["chapter": 6, "note": nil, "source_device": "x"])
  }

  @Test func shouldDeriveEveryRefFromTheKeyOfItsKind() {
    let novel = SchemaFixture.novel
    let secret = SecretRecord(novel: novel, secret: "heir", text: "t")
    let entity = EntityRecord(novel: novel, entity: "aria", type: .known(.character), name: "Aria")
    let reveal = CharacterKnowledgeRecord(novel: novel, fact: "heir", entity: "aria", reveal: ManualReveal(chapter: 3))
    let page = PageRecord(novel: novel, section: .world, slug: "harbour")
    let notes = AuthorNotesRecord(novel: novel, content: AuthorNotesContent(text: "n"))
    #expect(secret.ref == secret.key.ref)
    #expect(entity.ref == entity.key.ref)
    #expect(reveal.ref == reveal.key.ref)
    #expect(page.ref == page.key.ref)
    #expect(notes.ref == notes.key.ref)
    let refs = [secret.ref, entity.ref, reveal.ref, page.ref, notes.ref]
    #expect(Set(refs).count == refs.count)
    #expect(secret.key.kind == .secret)
    #expect(entity.key.kind == .entity)
    #expect(reveal.key.kind == .characterKnowledge)
    #expect(page.key.kind == .page)
    #expect(notes.key.kind == .authorNotes)
  }

  @Test func shouldNormaliseKeysTheWayTheStoreDoes() async throws {
    let store = try SchemaFixture.store()
    let secret = SecretRecord(novel: SchemaFixture.novel, secret: "e\u{301}clair", text: "t")
    #expect(secret.secret == "\u{E9}clair")
    _ = try await Harness.create(secret, in: store)
    expectLive(try await Harness.read(SecretRecord.ref(novel: SchemaFixture.novel, secret: "\u{E9}clair"), as: SecretRecord.self, in: store), secret)
    let reveal = CharacterKnowledgeRecord(novel: SchemaFixture.novel, fact: "e\u{301}clair", entity: "a\u{301}ria", reveal: ManualReveal(chapter: 1))
    #expect((reveal.fact, reveal.entity) == ("\u{E9}clair", "\u{E1}ria"))
    #expect(reveal.secretRef == secret.ref)
  }

  @Test func shouldKeepRecordsOfDifferentKindsApartEvenWhenTheirKeysMatch() async throws {
    let store = try SchemaFixture.store()
    let secret = SecretRecord(novel: SchemaFixture.novel, secret: "aria", text: "t")
    let entity = EntityRecord(novel: SchemaFixture.novel, entity: "aria", type: .known(.character), name: "Aria")
    _ = try await Harness.create(secret, in: store)
    _ = try await Harness.create(entity, in: store)
    expectLive(try await Harness.read(secret.ref, as: SecretRecord.self, in: store), secret)
    expectLive(try await Harness.read(entity.ref, as: EntityRecord.self, in: store), entity)
    #expect(try await Harness.read(entity.ref, as: SecretRecord.self, in: store) == .unreadable(.naturalKey(.keyMismatch(entity.ref))))
  }

  @Test func shouldSetAnOptionalToNullOnlyWhenTheEditSaysSo() async throws {
    let store = try SchemaFixture.store()
    let record = SecretRecord(novel: SchemaFixture.novel, secret: "heir", text: "t", writerNote: "w", unlock: ["all": [["ending": true]]])
    _ = try await Harness.create(record, in: store)
    var edit = SecretEdit()
    edit.writerNote = .set(nil)
    edit.unlock = .set(nil)
    let change = try await store.write { [edit] transaction in try SecretRecord.edit(novel: SchemaFixture.novel, secret: "heir", edit, in: &transaction) }
    #expect(change.fields == ["writer_note": .null, "unlock": .null])
    var expected = record
    expected.writerNote = nil
    expected.unlock = nil
    expectLive(try await Harness.read(record.ref, as: SecretRecord.self, in: store), expected)
  }

  @Test func shouldRejectAnEditThatChangesNothing() async throws {
    let store = try SchemaFixture.store()
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in try EntityRecord.edit(novel: SchemaFixture.novel, entity: "aria", EntityEdit(), in: &transaction) }
    }
  }

  @Test func shouldLetASecretEditSetEverySecretFieldAndNothingElse() {
    editCoverage(SecretField.self) { field in
      var edit = SecretEdit()
      switch field {
      case .text: edit.text = .set("t")
      case .subjects: edit.subjects = .set(nil)
      case .constraintNote: edit.constraintNote = .set(nil)
      case .writerNote: edit.writerNote = .set(nil)
      case .cluesAndTerms: edit.cluesAndTerms = .set(CluesAndTerms(clues: ["c"], terms: nil))
      case .revealChapter: edit.revealChapter = .set(nil)
      case .unlock: edit.unlock = .set(nil)
      case .source: edit.source = .set(.known(.seed))
      }
      return edit.fields
    }
  }

  @Test func shouldLetAnEntityEditSetEveryEntityFieldAndNothingElse() {
    editCoverage(EntityField.self) { field in
      var edit = EntityEdit()
      switch field {
      case .type: edit.type = .set(.known(.faction))
      case .name: edit.name = .set("n")
      case .attributes: edit.attributes = .set(nil)
      case .significance: edit.significance = .set(.known(.minor))
      case .status: edit.status = .set(nil)
      case .origin: edit.origin = .set(nil)
      case .notes: edit.notes = .set(nil)
      case .motivation: edit.motivation = .set(nil)
      case .body: edit.body = .set(nil)
      case .appearance: edit.appearance = .set(nil)
      case .wikiVisibility: edit.wikiVisibility = .set(.known(.hidden))
      case .age: edit.age = .set(16)
      }
      return edit.fields
    }
  }

  @Test func shouldLetAManualRevealEditSetEveryRevealFieldAndNothingElse() {
    editCoverage(CharacterKnowledgeField.self) { field in
      var edit = CharacterKnowledgeEdit()
      switch field {
      case .reveal: edit.reveal = .set(ManualReveal(chapter: 2, note: nil))
      }
      return edit.fields
    }
  }

  @Test func shouldHideAManualRevealWhoseSecretOrEntityIsRemovedOrMissingWithoutWritingToIt() async throws {
    let store = try SchemaFixture.store()
    let novel = SchemaFixture.novel
    let heir = SecretRecord(novel: novel, secret: "heir", text: "t")
    let crown = SecretRecord(novel: novel, secret: "crown", text: "t")
    let aria = EntityRecord(novel: novel, entity: "aria", type: .known(.character), name: "Aria")
    let brook = EntityRecord(novel: novel, entity: "brook", type: .known(.character), name: "Brook")
    for record in [heir, crown] { _ = try await Harness.create(record, in: store) }
    for record in [aria, brook] { _ = try await Harness.create(record, in: store) }
    let reveals = [("heir", "aria"), ("heir", "brook"), ("crown", "aria"), ("crown", "ghost"), ("lost", "aria")].map {
      CharacterKnowledgeRecord(novel: novel, fact: $0.0, entity: $0.1, reveal: ManualReveal(chapter: 4))
    }
    for reveal in reveals { _ = try await Harness.create(reveal, in: store) }
    func visible() async throws -> [String] {
      try await store.read { transaction in try CharacterKnowledgeRecord.visible(novel: novel, in: transaction) }.map { "\($0.fact)/\($0.entity)" }.sorted()
    }
    #expect(try await visible() == ["crown/aria", "heir/aria", "heir/brook"])

    let before = try await SchemaFixture.record(reveals[0].ref, in: store)
    _ = try await Harness.remove(brook, in: store)
    _ = try await Harness.remove(crown, in: store)
    #expect(try await visible() == ["heir/aria"])
    #expect(try await SchemaFixture.record(reveals[0].ref, in: store) == before)
    expectLive(try await Harness.read(reveals[1].ref, as: CharacterKnowledgeRecord.self, in: store), reveals[1])

    _ = try await Harness.restore(brook, in: store)
    _ = try await Harness.remove(reveals[0], in: store)
    #expect(try await visible() == ["heir/brook"])
  }
}
