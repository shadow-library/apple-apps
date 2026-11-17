import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = ChatWorld

private func expectConsistent(_ reconciler: NovelForgeReconciler, in store: VaultStore) async throws {
  let comparison = try await Projection.compare(reconciler, in: store)
  #expect(comparison.incremental == comparison.rebuilt)
  #expect(try await Projection.faults(reconciler, in: store).isEmpty)
}

private func keys(_ messages: [ChatMessageRecord]) -> [EntityKey] { messages.map(\.ref.key) }

@Suite("Chat session derivations", .timeLimit(.minutes(3)))
struct ChatSessionDerivationTests {
  @Test func shouldRecordEachMessageWithItsSessionRoleLinksAndClock() async throws {
    let (reconciler, store) = try World.store()
    try await World.createSession(in: store)
    let question = try World.message(role: .assistant, content: "Which heir?")
    let answer = try World.message(answers: question.id, cardProposal: SchemaFixture.proposal, appliedProposal: SchemaFixture.proposal)
    try await World.append(question, in: store)
    try await World.append(answer, in: store)
    let row = try #require(try await World.row(answer.ref, in: store))
    #expect(row.session == World.session && row.novel == World.novel && row.role == .known(.user) && row.isReadable)
    #expect(row.answers == question.id && row.cardProposal == SchemaFixture.proposal && row.appliedProposal == SchemaFixture.proposal)
    #expect(!row.hasUnreadableContexts && !row.hasUnreadableQuestion && row.id == answer.id)
    let clock = try await store.read { transaction in try ChatMessageRecord.read(answer.ref, in: transaction).entry?.clock }
    #expect(row.clock == clock)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldFlagUnreadablePartsAndKeepAnUnreadableMessageInItsSession() async throws {
    let (reconciler, store) = try World.store()
    try await World.createSession(in: store)
    let flagged = NovelForgeKey.chatMessage(UUID())
    try await World.appendRaw(
      flagged, World.item(["role": "user", "content": "See this.", "contexts": .array([.int(1)]), "question": ["question": 1]]), in: store)
    let unreadable = NovelForgeKey.chatMessage(UUID())
    try await World.appendRaw(unreadable, World.item(["role": "assistant", "content_mode": "unrestricted"]), in: store)
    let lost = NovelForgeKey.chatMessage(UUID())
    try await World.appendRaw(lost, ["novel": World.novel.json, "role": "user", "content": "Where?"], in: store)

    let row = try #require(try await World.row(flagged, in: store))
    #expect(row.isReadable && row.hasUnreadableContexts && row.hasUnreadableQuestion)
    let broken = try #require(try await World.row(unreadable, in: store))
    #expect(!broken.isReadable && broken.role == .known(.assistant) && broken.contentMode == .known(.unrestricted))
    #expect(try await World.row(lost, in: store) == nil)
    let state = try #require(try await World.state(in: store))
    #expect(state.messages == 2 && state.unreadableMessages == 1 && state.isStarted)
    #expect(state.lock?.item == unreadable)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldOrderTheTranscriptByClockThenRefWhateverTheArrivalOrder() async throws {
    let reconciler = try World.reconciler()
    let (first, second, reader) = (try Projection.store(reconciler), try Projection.store(reconciler), try Projection.store(reconciler))
    try await World.createSession(in: first)
    let early = try World.message(content: "Early")
    try await World.append(early, in: first)
    try await Projection.apply(try await Projection.lines(of: first), to: second)
    let late = try World.message(role: .assistant, content: "Late")
    try await World.append(late, in: second)
    let lateLines = try await Projection.lines(of: second)
    try await Projection.apply(Array(lateLines.suffix(1)), to: reader)
    #expect(try await World.state(in: reader)?.record == .absent)
    try await Projection.apply(try await Projection.lines(of: first), to: reader)
    let transcript = try await World.transcript(in: reader)
    #expect(transcript.map(\.message) == keys([early, late]) && transcript.map(\.position) == [1, 2])
    let state = try await World.state(in: reader)
    #expect(state?.record == .live && state?.latest == late.ref.key)
    try await expectConsistent(reconciler, in: reader)
  }

  @Test func shouldFollowTheChronologicalOrderOfTheMessageListing() async throws {
    let (reconciler, store) = try World.store()
    let messages = try (0..<5).map { _ in try World.message() }
    _ = try await Projection.write(store) { transaction in
      for message in messages.reversed() { _ = try message.append(in: &transaction) }
    }
    let expected = try await store.read { transaction in
      try ChatMessageRecord.listing(session: World.session, novel: World.novel, in: transaction).entries.map(\.record.ref.key)
    }
    #expect(try await World.transcript(in: store).map(\.message) == expected)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldTakeTheNovelFromTheRecordAndLeaveOutMessagesOfAnotherNovel() async throws {
    let (reconciler, store) = try World.store()
    let foreign = try World.message(novel: World.otherNovel, mode: .unrestricted)
    try await World.append(foreign, in: store)
    #expect(try await World.state(in: store)?.novel == World.otherNovel)
    try await World.createSession(in: store)
    let own = try World.message()
    try await World.append(own, in: store)
    let state = try #require(try await World.state(in: store))
    #expect(state.novel == World.novel && state.messages == 1 && state.unreadableMessages == 1)
    #expect(try await World.transcript(in: store).map(\.message) == keys([own]))
    #expect(state.lock?.item == foreign.ref)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldReadTheNovelOfASessionRecordThisVersionCannotRead() async throws {
    let (reconciler, store) = try World.store()
    try await Projection.set(NovelForgeKey.chatSession(World.session), ["novel": World.otherNovel.json, "mode": .int(2)], in: store)
    try await World.append(try World.message(novel: World.otherNovel), in: store)
    let state = try #require(try await World.state(in: store))
    #expect(state.record == .unreadable && state.novel == World.otherNovel && state.messages == 1)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldKeepARemovedSessionWithItsCountsAndLock() async throws {
    let (reconciler, store) = try World.store()
    try await World.createSession(in: store)
    try await World.append(try World.message(mode: .unrestricted), in: store)
    _ = try await Projection.write(store) { transaction in try ChatSessionRecord.remove(id: World.session, in: &transaction) }
    let state = try #require(try await World.state(in: store))
    #expect(state.record == .removed && state.messages == 1 && state.isLocked)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldStandTheSummaryCoveringTheMostMessagesThenTheNewest() async throws {
    let (reconciler, store) = try World.store()
    try await World.createSession(in: store)
    let messages = try (0..<4).map { index in try World.message(content: "Turn \(index)") }
    for message in messages { try await World.append(message, in: store) }
    let wide = try World.summary(covering: messages.prefix(3).map(\.id))
    let narrow = try World.summary(covering: messages.prefix(2).map(\.id))
    try await World.append(wide, in: store)
    try await World.append(narrow, in: store)
    #expect(try await World.state(in: store)?.summary == wide.ref.key)
    #expect(try await World.transcript(in: store).map(\.isCovered) == [true, true, true, false])

    let equal = try World.summary(covering: [messages[0].id, messages[1].id, messages[3].id, messages[3].id])
    try await World.append(equal, in: store)
    #expect(try await World.state(in: store)?.summary == equal.ref.key)
    #expect(try await World.transcript(in: store).map(\.isCovered) == [true, true, false, true])

    let foreign = try World.summary(novel: World.otherNovel, covering: messages.map(\.id))
    try await World.appendRaw(NovelForgeKey.chatSummary(UUID()), World.item(["covered": "all"]), in: store)
    try await World.append(foreign, in: store)
    let state = try #require(try await World.state(in: store))
    #expect(state.summary == equal.ref.key && state.unreadableSummaries == 2)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldLockOnTheEarliestUnrestrictedItemAndNeverOnAStandardOne() async throws {
    let (reconciler, store) = try World.store()
    try await World.createSession(in: store)
    try await World.append(try World.message(mode: .standard), in: store)
    try await World.append(try World.message(), in: store)
    try await World.append(try World.summary(covering: [UUID()]), in: store)
    try await World.appendRaw(NovelForgeKey.chatSummary(UUID()), World.item(["content_mode": "standard"]), in: store)
    #expect(try await World.state(in: store)?.lock == nil)

    let summary = try World.summary(covering: [UUID()], mode: .unrestricted)
    try await World.append(summary, in: store)
    try await World.append(try World.message(role: .assistant, mode: .unrestricted), in: store)
    let lock = try #require(try await World.state(in: store)?.lock)
    #expect(lock.item == summary.ref)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldLockOnAModeThisVersionDoesNotKnowAndOnASummaryWithNoReadableMode() async throws {
    for item in [World.item(["content_mode": "explicit"]), World.item(["content_mode": .int(1)])] {
      let (reconciler, store) = try World.store()
      let ref = NovelForgeKey.chatMessage(UUID())
      try await World.appendRaw(ref, item, in: store)
      #expect(try await World.state(in: store)?.lock?.item == ref)
      try await expectConsistent(reconciler, in: store)
    }
    let (reconciler, store) = try World.store()
    let summary = NovelForgeKey.chatSummary(UUID())
    try await World.appendRaw(summary, World.item(["text": "Folded."]), in: store)
    #expect(try await World.state(in: store)?.lock?.item == summary)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldMoveTheLockToAnEarlierItemThatArrivesLateButNeverLiftIt() async throws {
    let reconciler = try World.reconciler()
    let later = SchemaTestClock()
    later.advance()
    let (writer, reader) = (try Projection.store(reconciler), try Projection.store(reconciler, clock: later))
    let early = try World.message(mode: .unrestricted)
    try await World.append(early, in: writer)
    let late = try World.message(role: .assistant, mode: .unrestricted)
    try await World.append(late, in: reader)
    #expect(try await World.state(in: reader)?.lock?.item == late.ref)
    try await Projection.apply(try await Projection.lines(of: writer), to: reader)
    #expect(try await World.state(in: reader)?.lock?.item == early.ref)
    try await expectConsistent(reconciler, in: reader)
  }

  @Test func shouldLockOnAReplyThatRecordsNoMode() async throws {
    let (reconciler, store) = try World.store()
    try await World.createSession(in: store)
    try await World.append(try World.message(mode: .standard), in: store)
    let reply = try World.message(role: .assistant, content: "Here is the scene.")
    try await World.append(reply, in: store)
    #expect(try await World.state(in: store)?.lock?.item == reply.ref)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldNotLockOnAnAuthorMessageThatRecordsNoMode() async throws {
    let (reconciler, store) = try World.store()
    try await World.createSession(in: store)
    try await World.append(try World.message(), in: store)
    try await World.append(try World.message(role: .assistant, mode: .standard), in: store)
    #expect(try await World.state(in: store)?.lock == nil)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldLockOnAnUnreadableModelessItemUnlessItsRoleReadsAsTheAuthor() async throws {
    let (reconciler, store) = try World.store()
    try await World.createSession(in: store)
    try await World.appendRaw(NovelForgeKey.chatMessage(UUID()), World.item(["role": "user"]), in: store)
    var state = try #require(try await World.state(in: store))
    #expect(state.lock == nil && !state.isStarted && state.unreadableMessages == 1)
    let unknown = NovelForgeKey.chatMessage(UUID())
    try await World.appendRaw(unknown, World.item(["role": .int(1)]), in: store)
    state = try #require(try await World.state(in: store))
    #expect(state.lock?.item == unknown && !state.isStarted)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldNotStartASessionOnRepliesAlone() async throws {
    let (_, store) = try World.store()
    try await World.createSession(in: store)
    try await World.append(try World.message(role: .assistant, content: "Welcome."), in: store)
    #expect(try await World.state(in: store)?.isStarted == false)
  }

  @Test func shouldNeverFailToReconcileArbitraryChatAndProposalValues() async throws {
    let reconciler = try World.reconciler()
    try await forAll(iterations: 10, seed: 0xF23A2) { generator in
      let store = try Projection.store(reconciler)
      let values: [JSONValue] = [
        .null, .int(1), .string("x"), .array([]), .object([:]), World.novel.json, World.session.json, "unrestricted", "standard", "applied", "pending",
      ]
      let members = ["novel", "session", "role", "content", "content_mode", "covered", "text", "contexts", "question", "answers"]
      for _ in 0..<20 {
        let id = generator.pick(from: World.proposals + World.sessions)
        let pick = generator.int(in: 0...4)
        var built = World.item()
        for member in members where generator.chance(0.4) { built[member] = generator.pick(from: values) }
        let item = built
        let fields = Dictionary(
          uniqueKeysWithValues: ["card", "decision", "applied", "novel", "title", "mode", "status", "removed"].filter { _ in generator.chance(0.4) }.map {
            ($0, generator.pick(from: values))
          })
        let change = try NovelForgeKey(novel: World.novel, .proposalChange(proposal: id, index: generator.int(in: 0...3)))
        do {
          _ = try await store.write { transaction in
            switch pick {
            case 0: _ = try transaction.append(NovelForgeKey.chatMessage(UUID()), item: item)
            case 1: _ = try transaction.append(NovelForgeKey.chatSummary(UUID()), item: item)
            case 2: _ = try transaction.set(NovelForgeKey.proposal(id), fields)
            case 3: _ = try transaction.set(change.ref, fields.merging(["natural_key": change.stored, "status": "applied"]) { first, _ in first })
            default: _ = try transaction.set(NovelForgeKey.chatSession(id), fields)
            }
          }
        } catch let error as StoreError {
          guard case .invalidChange = error else { throw error }
        }
      }
      let comparison = try await Projection.compare(reconciler, in: store)
      #expect(comparison.incremental == comparison.rebuilt)
      #expect(try await Projection.faults(reconciler, in: store).isEmpty)
    }
  }
}
