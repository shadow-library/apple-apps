import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import ShadowAI

@Suite("Spend summary read from the ledger", .timeLimit(.minutes(1)))
struct SpendSummaryReaderTests {
  private static let day: Int64 = 86_400_000

  @Test("should equal the summary of the decoded entries")
  func matchesDecodedEntries() async throws {
    let clock = LedgerTestClock()
    let store = try LedgerFixture.store(clock)
    let now = clock.millis
    let entries = [
      LedgerFixture.entry(startedMillis: now, outcome: .finished, cost: Cost(nanoUSD: 7), costSource: .computed),
      LedgerFixture.entry(startedMillis: now - Self.day, outcome: .finished, cost: Cost(nanoUSD: 11), costSource: .reported),
      LedgerFixture.entry(startedMillis: now - 40 * Self.day, outcome: .finished, cost: Cost(nanoUSD: 1_000), costSource: .computed),
      LedgerFixture.entry(startedMillis: now, outcome: .started),
      LedgerFixture.entry(startedMillis: now, requestID: nil, generationID: "g1", outcome: .failed),
      LedgerFixture.entry(startedMillis: now, generationID: nil, outcome: .cancelled),
      LedgerFixture.entry(pace: nil, startedMillis: now, parent: UUID(), outcome: .failed),
    ]
    for entry in entries { try await LedgerFixture.open(entry, in: store) }
    try await store.write { transaction in
      _ = try transaction.set(Ledger.ref(UUID()), ["outcome": .string("finished")])
    }

    let (lean, decoded) = try await store.read { transaction in
      (
        try Spend.summary(in: transaction, now: clock.now, calendar: RoutingFixture.utc),
        Spend.summary(of: try Ledger.entries(in: transaction), now: clock.now, calendar: RoutingFixture.utc)
      )
    }
    #expect(lean == decoded)
    #expect(lean?.today == Cost(nanoUSD: 7))
    #expect(lean?.pendingCalls == 2)
  }
}
