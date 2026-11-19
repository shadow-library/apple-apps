import Foundation
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("RoutedCall streaming structured", TestTimeLimit.quick)
struct StructuredStreamRoutedTests {
  private typealias Fixture = StructuredStreamFixture

  private static let openRouterModels = [RemoteModel(id: "or/steady", supportsJSONSchema: true)]

  private static func prepare(_ provider: any ModelProvider, kind: ModelProviderKind = .openRouter) async throws -> (call: RoutedCall, store: VaultStore) {
    let clock = LedgerTestClock()
    let store = try LedgerFixture.store(clock)
    try await RoutingFixture.grantConsent(host: RoutingFixture.binding(kind, provider).host, in: store)
    let configuration = RoutingFixture.configuration(kind, openRouterModels: openRouterModels)
    let router = RoutingFixture.router(
      configuration, anthropic: kind == .anthropic ? provider : nil, openRouter: kind == .openRouter ? provider : nil, store: store, clock: clock)
    return (try await router.prepare(RoutingFixture.call()), store)
  }

  private static func ask(_ call: RoutedCall) -> ModelRequest {
    call.request(system: [ContextSegment(text: "You outline novels.")], messages: [.user("Outline the novel.")])
  }

  @Test("should return every request's ledger id with a repaired answer")
  func returnsCallIDs() async throws {
    let base = ScriptedModelProvider(calls: [
      ScriptedModelProvider.reply(Fixture.descending, generationID: "g1"), ScriptedModelProvider.reply(Fixture.ascending, generationID: "g2"),
    ])
    let (call, store) = try await Self.prepare(base, kind: .anthropic)

    let result = try await call.streamStructured(Self.ask(call), name: "outline", schema: Fixture.schema, review: Fixture.review)
    await call.settled()

    #expect(result.wasRepaired)
    #expect(result.callIDs.count == 2)
    #expect(result.callIDs == call.callIDs)
    #expect(Set(try await LedgerFixture.entries(store).map(\.id)) == Set(result.callIDs))
  }

  @Test("should fall back from native to the prompt form inside one stream, numbering every attempt and ledgering each")
  func fallbackInterplay() async throws {
    let invalid = #"Here: {"title":"The Ferry","chapters":"one"}"#
    let base = ScriptedModelProvider(calls: [[.failure(.noEligibleModel)], ScriptedModelProvider.reply(invalid), ScriptedModelProvider.reply(Fixture.ascending)])
    let (call, store) = try await Self.prepare(base)
    var events: [StructuredStreamEvent] = []

    let result = try await call.streamStructured(Self.ask(call), name: "outline", schema: Fixture.schema, review: Fixture.review, observer: { events.append($0) })
    await call.settled()

    #expect(
      events.map(Fixture.describe)
        == ["attempt 1 native answer", "attempt 2 prompt answer"] + Fixture.deltas(invalid) + ["attempt 3 prompt repair", "reset"] + Fixture.deltas(Fixture.ascending)
        + ["succeeded"])
    #expect(events.last == .completed(.succeeded(result)))
    #expect(result.mode == .prompt)
    #expect(result.wasRepaired)
    #expect(result.responses.map(\.text) == [invalid, Fixture.ascending])
    #expect(result.callIDs == call.callIDs)
    #expect(result.callIDs.count == 3)
    guard case .json? = base.requests.first?.format else {
      Issue.record("expected the first request in native mode")
      return
    }
    #expect(base.requests.dropFirst().map(\.format) == [.text, .text])
    let entries = try await LedgerFixture.entries(store)
    #expect(entries.count == 3)
    #expect(entries.filter { $0.outcome == .finished }.count == 2)
    #expect(entries.filter { $0.outcome == .failed }.count == 1)
  }

  @Test("should leave a call cancelled mid-stream pending in the ledger and return its partial text")
  func cancelMidStream() async throws {
    let clock = ManualClock(.manual)
    let base = ScriptedModelProvider(
      calls: [[.event(.started(requestID: "r1", generationID: "g1")), .text(#"{"title":"The"#), .delay(.seconds(60)), .text(#" Ferry","chapters":[1]}"#)]], clock: clock)
    let (call, store) = try await Self.prepare(base)
    let shown = Signal()
    let consumer = Task { () -> (failure: StructuredStreamFailure?, events: [StructuredStreamEvent]) in
      var events: [StructuredStreamEvent] = []
      do throws(StructuredStreamFailure) {
        _ = try await call.streamStructured(
          Self.ask(call), name: "outline", schema: Fixture.schema,
          observer: { event in
            events.append(event)
            if case .textDelta = event { shown.fire() }
          })
        return (nil, events)
      } catch {
        return (error, events)
      }
    }
    await shown.wait()
    consumer.cancel()
    let (failure, events) = await consumer.value
    await call.settled()

    #expect(failure?.error == .model(.cancelled, responses: []))
    #expect(failure?.partialText == #"{"title":"The"#)
    #expect(failure?.callIDs == call.callIDs)
    #expect(events.map(Fixture.describe) == ["attempt 1 native answer", #"delta {"title":"The"#, "failed model.cancelled"])
    let entries = try await LedgerFixture.entries(store)
    #expect(entries.map(\.outcome) == [.started])
    #expect(entries.map(\.costSource) == [.pending])
    #expect(entries.first?.generationID == "g1")
    #expect(call.callIDs == entries.map(\.id))
    #expect(base.requests.count == 1)
  }

  @Test("should give two concurrent calls on one RoutedCall exactly their own ids")
  func concurrentCallIDs() async throws {
    let clock = ManualClock(.manual)
    let base = ScriptedModelProvider(
      calls: [
        [.event(.started(requestID: nil, generationID: nil)), .delay(.seconds(1))] + ScriptedModelProvider.reply(Fixture.descending).dropFirst(),
        [.event(.started(requestID: nil, generationID: nil)), .delay(.seconds(1))] + ScriptedModelProvider.reply(Fixture.ascending).dropFirst(),
        ScriptedModelProvider.reply(Fixture.ascending),
      ], clock: clock)
    let (call, store) = try await Self.prepare(base, kind: .anthropic)

    async let first = call.streamStructured(Self.ask(call), name: "outline", schema: Fixture.schema, review: Fixture.review)
    async let second = call.streamStructured(Self.ask(call), name: "outline", schema: Fixture.schema, review: Fixture.review)
    await clock.waitForSleepers(2)
    clock.advance(by: .seconds(1))
    let results = try await [first, second]
    await call.settled()

    #expect(results.map(\.callIDs.count).sorted() == [1, 2])
    #expect(Set(results[0].callIDs).isDisjoint(with: results[1].callIDs))
    #expect(Set(results[0].callIDs + results[1].callIDs) == Set(call.callIDs))
    #expect(call.callIDs.count == 3)
    #expect(Set(try await LedgerFixture.entries(store).map(\.id)) == Set(call.callIDs))
  }

  @Test("should keep the first reply, the repair's partial text and both ids when cancelled during the repair")
  func cancelDuringRepair() async throws {
    let clock = ManualClock(.manual)
    let base = ScriptedModelProvider(
      calls: [
        ScriptedModelProvider.reply(Fixture.descending, generationID: "g1"),
        [.event(.started(requestID: "r2", generationID: "g2")), .text(#"{"title":"#), .delay(.seconds(60)), .text(#""The Ferry","chapters":[1,2]}"#)],
      ], clock: clock)
    let (call, store) = try await Self.prepare(base, kind: .anthropic)
    let repairing = Signal()
    let consumer = Task { () -> (failure: StructuredStreamFailure?, events: [StructuredStreamEvent]) in
      var events: [StructuredStreamEvent] = []
      do throws(StructuredStreamFailure) {
        _ = try await call.streamStructured(
          Self.ask(call), name: "outline", schema: Fixture.schema, review: Fixture.review,
          observer: { event in
            events.append(event)
            if case .textDelta(#"{"title":"#) = event { repairing.fire() }
          })
        return (nil, events)
      } catch {
        return (error, events)
      }
    }
    await repairing.wait()
    consumer.cancel()
    let (failure, events) = await consumer.value
    await call.settled()

    let first = ModelResponse(
      text: Fixture.descending, usage: TokenUsage(input: 10, output: 5), reportedCost: nil, stop: .endTurn, requestID: "req_scripted", generationID: "g1")
    #expect(failure?.error == .model(.cancelled, responses: [first]))
    #expect(failure?.partialText == #"{"title":"#)
    #expect(failure?.callIDs == call.callIDs)
    #expect(call.callIDs.count == 2)
    #expect(events.map(Fixture.describe).suffix(4) == ["attempt 2 native repair", "reset", #"delta {"title":"#, "failed model.cancelled"])
    let entries = try await LedgerFixture.entries(store)
    #expect(entries.filter { $0.outcome == .finished }.count == 1)
    #expect(entries.filter { $0.outcome == .started }.map(\.costSource) == [.pending])
  }

  @Test("should include the id of a request cancelled while its ledger entry was being written", arguments: 0..<40)
  func callIDsOnEarlyCancel(round: Int) async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply(Fixture.ascending)])
    let (call, store) = try await Self.prepare(base, kind: .anthropic)
    let consumer = Task { () -> StructuredStreamFailure? in
      do throws(StructuredStreamFailure) {
        _ = try await call.streamStructured(Self.ask(call), name: "outline", schema: Fixture.schema)
        return nil
      } catch {
        return error
      }
    }
    consumer.cancel()
    let failure = await consumer.value
    await call.settled()

    let ids = try await LedgerFixture.entries(store).map(\.id)
    if let failure { #expect(failure.callIDs == ids) }
    #expect(call.callIDs == ids)
  }
}
