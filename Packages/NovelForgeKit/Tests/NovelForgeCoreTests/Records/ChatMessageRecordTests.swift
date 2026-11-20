import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let other = SchemaFixture.otherNovel
private let session = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000b1")
private let wrong = JSONValue.array([.null])

private func context(_ generator: inout SeededGenerator) -> ChatPassageContext {
  let start = generator.int(in: 0...400)
  let quote = Gen.text(&generator) + "x"
  return ChatPassageContext(
    chapter: generator.int(in: 1...40), draftId: String(generator.int(in: 1...900)), revision: generator.int(in: 0...9), saveSeq: generator.int(in: 0...9), start: start,
    end: start + quote.utf16.count, passageHash: String(repeating: "a", count: 64), quote: quote, comment: Gen.text(&generator), firstParagraph: 1, lastParagraph: 2)
}

private func card(_ generator: inout SeededGenerator) -> ChatQuestion {
  let answers = (0..<generator.int(in: 2...4)).map { _ in
    ChatQuestionAnswer(
      title: Gen.text(&generator) + "t", why: Gen.optionalText(&generator), tradeOff: Gen.optionalText(&generator), recommended: generator.chance(0.3))
  }
  return ChatQuestion(question: Gen.text(&generator) + "?", why: Gen.optionalText(&generator), answers: answers, progressKey: generator.chance(0.5) ? nil : "premise")
}

extension Gen {
  static func chatMessage(_ generator: inout SeededGenerator, novel: UUID, session: UUID = session, role: ChatRole? = nil) throws -> ChatMessageRecord {
    let role = role ?? (generator.chance(0.5) ? .user : .assistant)
    let contexts = generator.chance(0.5) ? nil : (0..<generator.int(in: 1...3)).map { _ in context(&generator).json }
    return try ChatMessageRecord(
      id: generator.uuid(), novel: novel, session: session, role: role, content: Gen.text(&generator) + "m", contexts: contexts,
      answers: generator.chance(0.5) ? nil : generator.uuid(), seen: generator.chance(0.5) ? nil : generator.uuid(),
      pace: generator.chance(0.5) ? nil : generator.pick(from: CostTier.allCases),
      deeper: generator.chance(0.5) ? nil : bool(&generator), contentMode: generator.chance(0.5) ? nil : generator.pick(from: ContentMode.allCases),
      justDiscussing: generator.chance(0.5) ? nil : bool(&generator), proseEdits: generator.chance(0.5) ? nil : bool(&generator), tokens: optionalInt(&generator),
      question: generator.chance(0.5) ? nil : card(&generator).stored, trace: optionalJSON(&generator),
      modelCalls: generator.chance(0.5) ? nil : [generator.uuid(), generator.uuid()], appliedProposal: generator.chance(0.5) ? nil : generator.uuid(),
      cardProposal: generator.chance(0.5) ? nil : generator.uuid(), applyNote: optionalText(&generator), held: optionalText(&generator))
  }
}

private func append(_ record: ChatMessageRecord, in store: VaultStore) async throws -> ChangeRecord {
  try await store.write { transaction in try record.append(in: &transaction) }
}

private func appendRaw(_ ref: EntityRef, _ item: [String: JSONValue], in store: VaultStore) async throws {
  _ = try await store.write { transaction in try transaction.append(ref, item: item) }
}

private func read(_ ref: EntityRef, in store: VaultStore) async throws -> AppendedReading<ChatMessageRecord> {
  try await store.read { transaction in try ChatMessageRecord.read(ref, in: transaction) }
}

@Suite("Chat message records", TestTimeLimit.standard)
struct ChatMessageRecordTests {
  @Test func shouldRoundTripMessagesUnderTheRefOfTheirId() async throws {
    let store = try SchemaFixture.store()
    try await forAll(iterations: 40, seed: 0xC601) { generator in
      let record = try Gen.chatMessage(&generator, novel: generator.uuid())
      #expect(record.ref == NovelForgeKey.chatMessage(record.id))
      #expect(try await read(record.ref, in: store) == .absent)
      let change = try await append(record, in: store)
      #expect(Set(change.fields.keys) == Set(ChatMessageMember.allCases.map(\.rawValue)))
      #expect(try await read(record.ref, in: store) == .readable(AppendedEntry(record: record, clock: change.clock)))
      await #expect(throws: StoreError.self) { try await append(record, in: store) }
    }
  }

  @Test func shouldStoreEveryLinkOfAReplyInTheTransactionThatCreatesIt() async throws {
    let store = try SchemaFixture.store()
    let user = try ChatMessageRecord(novel: novel, session: session, role: .user, content: "Make her warier", pace: .balanced, deeper: false, proseEdits: true)
    let reply = try ChatMessageRecord(
      novel: novel, session: session, role: .assistant, content: "Done", answers: nil, seen: user.id, tokens: 12, modelCalls: [UUID()],
      appliedProposal: UUID(), cardProposal: UUID(),
      applyNote: "Applied 2 changes", held: "warnings")
    for record in [user, reply] { _ = try await append(record, in: store) }
    await #expect(throws: StoreError.self) { try await SchemaFixture.set(reply.ref, ["held": "warnings"], in: store) }
    #expect(try await read(reply.ref, in: store).entry?.record == reply)
  }

  @Test func shouldReadAMessageTotally() async throws {
    let store = try SchemaFixture.store()
    try await forAll(iterations: 3, seed: 0xC602) { generator in
      let required: Set<String> = ["novel", "session", "role", "content"]
      let anyJSON: Set<String> = ["trace", "contexts", "question"]
      let sample = try Gen.chatMessage(&generator, novel: novel)
      for name in sample.item.keys.sorted() {
        let missing = try Gen.chatMessage(&generator, novel: novel)
        var item = missing.item
        item[name] = nil
        try await appendRaw(missing.ref, item, in: store)
        let afterRemoval = try await read(missing.ref, in: store)
        if required.contains(name) {
          #expect(afterRemoval == .unreadable(.missing(field: name)), "missing \(name)")
        } else {
          #expect(afterRemoval.entry?.record.item[name] == JSONValue.null, "missing \(name)")
        }

        let corrupt = try Gen.chatMessage(&generator, novel: novel)
        item = corrupt.item
        item[name] = wrong
        try await appendRaw(corrupt.ref, item, in: store)
        let afterCorruption = try await read(corrupt.ref, in: store)
        if anyJSON.contains(name) {
          #expect(afterCorruption.entry?.record.item[name] == wrong, "\(name) carries any JSON")
        } else {
          #expect(afterCorruption == .unreadable(.invalid(field: name)), "wrong type \(name)")
        }
      }
    }
  }

  @Test func shouldKeepNewerMembersAndUnknownEnumValues() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0xC603)
    let record = try Gen.chatMessage(&generator, novel: novel)
    var item = record.item
    item[Harness.newerMember] = ["nested": [1, 2]]
    item["role"] = "narrator"
    item["pace"] = "x_turbo"
    item["content_mode"] = "x_mode"
    try await appendRaw(record.ref, item, in: store)
    let carried = try #require(try await read(record.ref, in: store).entry?.record)
    #expect(carried.item == item)
    #expect(carried.unrecognised == [Harness.newerMember: ["nested": [1, 2]]])
    #expect(carried.role == .unknown("narrator"))
    #expect(carried.pace == .unknown("x_turbo"))
    #expect(carried.contentMode == .unknown("x_mode"))
  }

  @Test func shouldRefuseWhatTheReferenceRefusesOfAnAuthorMessage() throws {
    #expect(throws: ChatRecordError.emptyMessage) { try ChatMessageRecord(novel: novel, session: session, role: .user, content: " \n ") }
    #expect(throws: ChatRecordError.contentTooLong(limit: 200_000)) {
      try ChatMessageRecord(novel: novel, session: session, role: .user, content: String(repeating: "a", count: 200_001))
    }
    #expect(throws: Never.self) { try ChatMessageRecord(novel: novel, session: session, role: .user, content: String(repeating: "😀", count: 200_000)) }
    #expect(throws: Never.self) { try ChatMessageRecord(novel: novel, session: session, role: .assistant, content: "") }
    #expect(throws: Never.self) { try ChatMessageRecord(novel: novel, session: session, role: .assistant, content: String(repeating: "a", count: 200_001)) }
  }

  @Test func shouldAcceptAnEmptyAuthorMessageThatCarriesAPassageAndStoreNoPassagesForAnEmptyList() throws {
    var generator = SeededGenerator(seed: 0xC604)
    let passage = context(&generator).json
    let commented = try ChatMessageRecord(novel: novel, session: session, role: .user, content: "", contexts: [passage])
    #expect(commented.contexts == [passage])
    #expect(try ChatMessageRecord(novel: novel, session: session, role: .assistant, content: "x", contexts: []).contexts == nil)
    #expect(throws: ChatRecordError.emptyMessage) { try ChatMessageRecord(novel: novel, session: session, role: .user, content: "", contexts: []) }
  }

  @Test func shouldBoundAndCheckPassageContexts() throws {
    var generator = SeededGenerator(seed: 0xC605)
    let passage = context(&generator).json
    #expect(throws: Never.self) { try ChatMessageRecord(novel: novel, session: session, role: .user, content: "x", contexts: Array(repeating: passage, count: 10)) }
    #expect(throws: ChatRecordError.tooManyContexts(limit: 10)) {
      try ChatMessageRecord(novel: novel, session: session, role: .user, content: "x", contexts: Array(repeating: passage, count: 11))
    }
    #expect(throws: ChatRecordError.malformedContext(index: 1)) { try ChatMessageRecord(novel: novel, session: session, role: .user, content: "x", contexts: [passage, wrong]) }
    var notAPassage = try #require(passage.objectValue)
    notAPassage["kind"] = "bible"
    #expect(throws: ChatRecordError.malformedContext(index: 0)) {
      try ChatMessageRecord(novel: novel, session: session, role: .user, content: "x", contexts: [.object(notAPassage)])
    }
  }

  @Test func shouldReadAMessageWithUndecodablePassagesOrQuestionIntactAndFlagThem() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0xC606)
    let record = try Gen.chatMessage(&generator, novel: novel, role: .assistant)
    let cases: [(member: String, value: JSONValue)] = [
      ("contexts", .array([wrong])), ("contexts", "a stray string"), ("contexts", ["kind": "passage"]), ("contexts", [1, "x"]), ("question", ["question": "q"]),
      ("question", wrong),
    ]
    for (member, value) in cases {
      var item = record.item
      item[member] = value
      item[Harness.newerMember] = ["nested": [1]]
      let ref = ChatMessageRecord.ref(UUID())
      try await appendRaw(ref, item, in: store)
      let read = try #require(try await read(ref, in: store).entry?.record)
      #expect(read.content == record.content)
      #expect(read.hasUnreadableContexts == (member == "contexts"))
      #expect(read.hasUnreadableQuestion == (member == "question"))
      #expect(read.unrecognised == [Harness.newerMember: ["nested": [1]]])
      #expect(read.item[member] == value)
    }
  }

  @Test func shouldBuildAMessageFromTypedPassagesAndAQuestion() throws {
    var generator = SeededGenerator(seed: 0xC60B)
    let (passage, question) = (context(&generator), card(&generator))
    let record = try ChatMessageRecord(novel: novel, session: session, role: .assistant, content: "x", passageContexts: [passage], question: question)
    #expect(record.passageContexts == [passage])
    #expect(record.questionCard == question)
    #expect(!record.hasUnreadableContexts && !record.hasUnreadableQuestion)
  }

  @Test func shouldRoundTripPassageContextsThroughTheirStoredShape() throws {
    var generator = SeededGenerator(seed: 0xC607)
    for _ in 0..<50 {
      let passage = context(&generator)
      #expect(ChatPassageContext(json: passage.json) == passage)
    }
    let stored = try #require(context(&generator).json.objectValue)
    #expect(Set(stored.keys) == Set(ChatPassageContextMember.allCases.map(\.rawValue)))
    #expect(stored["kind"] == "passage")
    let record = try ChatMessageRecord(novel: novel, session: session, role: .user, content: "x", contexts: [.object(stored)])
    #expect(record.passageContexts?.count == 1)
  }

  @Test func shouldRoundTripAQuestionCardInTheShapeThePolicyEmits() throws {
    var generator = SeededGenerator(seed: 0xC608)
    for _ in 0..<50 {
      let question = card(&generator)
      #expect(ChatQuestion(stored: question.stored) == question)
      let policyKeys = Set(try #require(question.json.objectValue).entries.map(\.key))
      #expect(Set(try #require(question.stored.objectValue).keys) == policyKeys)
      let record = try ChatMessageRecord(novel: novel, session: session, role: .assistant, content: "x", question: question.stored)
      #expect(record.questionCard == question)
    }
  }

  @Test func shouldRefuseAQuestionCardOutsideTwoToFourAnswers() throws {
    var generator = SeededGenerator(seed: 0xC609)
    let valid = card(&generator)
    var lone = valid
    lone.answers = Array(valid.answers.prefix(1))
    var crowded = valid
    crowded.answers = Array(repeating: valid.answers[0], count: 5)
    var blank = valid
    blank.question = "  "
    for question in [lone, crowded, blank] {
      #expect(throws: ChatRecordError.malformedQuestion) { try ChatMessageRecord(novel: novel, session: session, role: .assistant, content: "x", question: question.stored) }
    }
    #expect(throws: ChatRecordError.malformedQuestion) { try ChatMessageRecord(novel: novel, session: session, role: .assistant, content: "x", question: wrong) }
  }

  @Test func shouldListOneSessionsMessagesOldestFirstWithBrokenOnesCounted() async throws {
    let store = try SchemaFixture.store()
    var generator = SeededGenerator(seed: 0xC60A)
    let otherSession = generator.uuid()
    var mine = [AppendedEntry<ChatMessageRecord>]()
    for _ in 0..<4 {
      let record = try Gen.chatMessage(&generator, novel: novel)
      mine.append(AppendedEntry(record: record, clock: try await append(record, in: store).clock))
    }
    _ = try await append(try Gen.chatMessage(&generator, novel: novel, session: otherSession), in: store)
    _ = try await append(try Gen.chatMessage(&generator, novel: other), in: store)
    let broken = try Gen.chatMessage(&generator, novel: novel)
    try await appendRaw(broken.ref, broken.item.merging(["content": wrong]) { _, bad in bad }, in: store)

    let listing = try await store.read { transaction in try ChatMessageRecord.listing(session: session, novel: novel, in: transaction) }
    #expect(listing.records == mine.map(\.record))
    #expect(listing.unreadable == 1)
  }
}
