import Foundation
import Testing

@testable import NovelForgeCore

private typealias Fixture = NotebookFixture

@Suite("Notebook resolution")
struct NotebookResolutionTests {
  private func resolve(_ entries: [AppendedEntry<NotebookEntryRecord>], _ withdrawals: [AppendedEntry<NotebookWithdrawalRecord>] = []) -> [UUID: NotebookEntryState] {
    NotebookResolution.resolve(entries: entries, withdrawals: withdrawals)
  }

  @Test func shouldKeepEveryEntryActiveWhenNothingSupersedesOrWithdrawsIt() {
    let (first, second) = (Fixture.entry(at: 1), Fixture.entry(at: 2))
    #expect(resolve([first, second]) == [first.record.id: .active, second.record.id: .active])
  }

  @Test func shouldMarkTheSupersededEntryAndKeepTheSuccessorActive() {
    let old = Fixture.entry(at: 1)
    let next = Fixture.entry(supersedes: old.record.id, at: 2)
    let states = resolve([old, next])
    #expect(states[old.record.id]?.status == .superseded)
    #expect(states[old.record.id]?.successor == next.record.id)
    #expect(states[next.record.id] == .active)
  }

  @Test func shouldMakeTheLaterClockTheSuccessorWhenTwoEntriesSupersedeTheSameOne() {
    let old = Fixture.entry(at: 1)
    let (early, late) = (Fixture.entry(supersedes: old.record.id, at: 5), Fixture.entry(supersedes: old.record.id, at: 9))
    for order in [[old, early, late], [late, early, old]] {
      let states = resolve(order)
      #expect(states[old.record.id]?.successor == late.record.id)
      #expect(states[early.record.id]?.successor == late.record.id)
      #expect(states[late.record.id] == .active)
    }
  }

  @Test func shouldLetTheLatestOfThreeConcurrentSupersedesWin() {
    let old = Fixture.entry(at: 1)
    let rewrites = [Fixture.entry(supersedes: old.record.id, at: 4), Fixture.entry(supersedes: old.record.id, at: 8), Fixture.entry(supersedes: old.record.id, at: 6)]
    let states = resolve([old] + rewrites)
    let active = rewrites.filter { states[$0.record.id]?.status == .active }
    #expect(active.map(\.record.id) == [rewrites[1].record.id])
    #expect(states[old.record.id]?.successor == rewrites[1].record.id)
  }

  @Test func shouldBreakAClockTieByTheEntryReference() {
    let old = Fixture.entry(at: 1)
    let (left, right) = (Fixture.entry(supersedes: old.record.id, at: 5), Fixture.entry(supersedes: old.record.id, at: 5))
    let later = [left, right].max { NotebookEntryRecord.chronologically($0, $1) }
    #expect(resolve([old, left, right])[old.record.id]?.successor == later?.record.id)
    #expect(resolve([right, left, old]) == resolve([old, left, right]))
  }

  @Test func shouldPreferTheLaterOfAnExplicitSuccessorAndAConcurrentSibling() {
    let old = Fixture.entry(at: 1)
    let (first, second) = (Fixture.entry(supersedes: old.record.id, at: 4), Fixture.entry(supersedes: old.record.id, at: 5))
    let third = Fixture.entry(supersedes: first.record.id, at: 7)
    let states = resolve([old, first, second, third])
    #expect(states[first.record.id]?.successor == third.record.id)
    #expect(states[second.record.id] == .active)
    #expect(states[old.record.id]?.successor == second.record.id)
  }

  @Test func shouldWithdrawAnEntryByItsEarliestWithdrawal() {
    let entry = Fixture.entry(at: 1)
    let (first, second) = (Fixture.withdrawal(of: entry.record.id, at: 3), Fixture.withdrawal(of: entry.record.id, at: 7))
    let state = resolve([entry], [second, first])[entry.record.id]
    #expect(state?.status == .withdrawn)
    #expect(state?.withdrawal == first.record.id)
  }

  @Test func shouldLabelAnEntryThatIsWithdrawnAndSupersededAsWithdrawnAndKeepTheSuccessorActive() {
    let old = Fixture.entry(at: 1)
    let next = Fixture.entry(supersedes: old.record.id, at: 4)
    let drop = Fixture.withdrawal(of: old.record.id, at: 2)
    let states = resolve([old, next], [drop])
    #expect(states[old.record.id] == NotebookEntryState(successor: next.record.id, withdrawal: drop.record.id))
    #expect(states[old.record.id]?.status == .withdrawn)
    #expect(states[next.record.id] == .active)
  }

  @Test func shouldIgnoreAWithdrawalOfAnUnknownEntryOrOfAnotherNovel() {
    let (mine, theirs) = (Fixture.entry(at: 1), Fixture.entry(novel: Fixture.other, at: 2))
    let states = resolve([mine, theirs], [Fixture.withdrawal(of: UUID(), at: 3), Fixture.withdrawal(of: theirs.record.id, at: 4)])
    #expect(states[mine.record.id] == .active)
    #expect(states[theirs.record.id] == .active)
  }

  @Test func shouldIgnoreASupersedeThatNamesItselfAnUnknownEntryOrAnotherNovelsEntry() {
    let id = UUID()
    let own = Fixture.entry(id, supersedes: id, at: 1)
    let dangling = Fixture.entry(supersedes: UUID(), at: 2)
    let foreign = Fixture.entry(novel: Fixture.other, at: 3)
    let crossing = Fixture.entry(supersedes: foreign.record.id, at: 4)
    let states = resolve([own, dangling, foreign, crossing])
    #expect(states.values.allSatisfy { $0 == .active })
    #expect(states.count == 4)
  }

  @Test func shouldSupersedeBothEntriesOfACycleWithoutLooping() {
    let (a, b) = (UUID(), UUID())
    let states = resolve([Fixture.entry(a, supersedes: b, at: 1), Fixture.entry(b, supersedes: a, at: 2)])
    #expect(states[a]?.successor == b)
    #expect(states[b]?.successor == a)
  }

  @Test func shouldGiveTheSameStatesInAnyInputOrder() {
    let old = Fixture.entry(at: 1)
    let entries = [old] + (2...6).map { Fixture.entry(supersedes: $0.isMultiple(of: 2) ? old.record.id : nil, at: Int64($0)) }
    let withdrawals = [Fixture.withdrawal(of: entries[2].record.id, at: 9), Fixture.withdrawal(of: old.record.id, at: 8)]
    #expect(resolve(entries.reversed(), withdrawals.reversed()) == resolve(entries, withdrawals))
  }
}
