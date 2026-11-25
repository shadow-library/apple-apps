import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Category edits", TestTimeLimit.quick)
struct CategoryEditsTests {
  private static let food = CategoryKey("food")!
  private static let groceries = CategoryKey("groceries")!

  private static func stores(_ records: [any MemoirRecord] = []) async throws -> MemoirStores {
    let stores = try MemoirStores.openInMemory()
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.settings()] + records)
    return stores
  }

  private static func set(_ key: CategoryKey, _ essential: Bool?, in stores: MemoirStores) async throws -> ExpenseCategoryRecord? {
    try await stores.main.write { transaction in try CategoryEdits.setEssential(key, essential, label: "Label", in: &transaction) }
  }

  private static func records(in stores: MemoirStores) async throws -> [ExpenseCategoryRecord] {
    try await stores.main.read { transaction in try ExpenseCategoryRecord.listing(in: transaction) }.entries.map(\.record)
  }

  private static func essentials(in stores: MemoirStores) async throws -> CategoryEssentials {
    CategoryEssentials(records: try await records(in: stores))
  }

  @Test func shouldWriteTheRecordOfACategoryWithoutOneWithoutItsArchivedFlag() async throws {
    let stores = try await Self.stores()
    #expect(try await Self.essentials(in: stores).essential(Self.food) == .byDefault(false))
    let written = try await Self.set(Self.food, true, in: stores)
    #expect(written == ExpenseCategoryRecord(key: Self.food, label: "Label", essential: true))
    #expect(try await Self.records(in: stores) == [ExpenseCategoryRecord(key: Self.food, label: "Label", essential: true)], "an absent flag reads unarchived")
    #expect(try await Self.essentials(in: stores).essential(Self.food) == .byOwner(true))
    let stored = try await stores.main.read { transaction in try transaction.state(of: MemoirKey.expenseCategory(Self.food).ref) }
    guard case .record(let state)? = stored else {
      Issue.record("the category is a record")
      return
    }
    #expect(state.fields[ExactString(ExpenseCategoryField.archived.rawValue)] == nil, "the archived flag is never written")
    #expect(state.fields[ExactString(ExpenseCategoryField.essential.rawValue)] != nil)
  }

  @Test func shouldKeepAnArchiveFromADeviceWhoseWriteHadNotArrived() async throws {
    for essentialLater in [true, false] {
      let replicas = try await CausalReplicas(CausalReplicaSetup(count: 2, registry: MemoirSchema.mainRegistry))
      let archive: @Sendable (inout WriteTransaction) throws -> Void = { transaction in
        try ExpenseCategoryRecord(key: Self.food, label: "Food", archived: true).create(in: &transaction)
      }
      let choose: @Sendable (inout WriteTransaction) throws -> Void = { transaction in
        _ = try CategoryEdits.setEssential(Self.food, true, label: "Food", in: &transaction)
      }
      if essentialLater {
        try await replicas.write(0, archive)
        await replicas.advanceClock(of: 1, by: .seconds(1))
        try await replicas.write(1, choose)
      } else {
        try await replicas.write(1, choose)
        await replicas.advanceClock(of: 0, by: .seconds(1))
        try await replicas.write(0, archive)
      }
      try await replicas.settle()
      for index in 0..<2 {
        let records = try await replicas.store(index).read { transaction in try ExpenseCategoryRecord.listing(in: transaction) }.entries.map(\.record)
        #expect(records == [ExpenseCategoryRecord(key: Self.food, label: "Food", archived: true, essential: true)], "replica \(index), essential later: \(essentialLater)")
      }
    }
  }

  @Test func shouldChangeOnlyTheEssentialFlagOfAnExistingRecord() async throws {
    let stores = try await Self.stores([ExpenseCategoryRecord(key: Self.groceries, label: "Weekly shop", archived: true)])
    #expect(try await Self.essentials(in: stores).isEssential(Self.groceries), "groceries are essential by default")
    _ = try await Self.set(Self.groceries, false, in: stores)
    #expect(try await Self.records(in: stores) == [ExpenseCategoryRecord(key: Self.groceries, label: "Weekly shop", archived: true, essential: false)])
    #expect(try await Self.essentials(in: stores).essential(Self.groceries) == .byOwner(false))
  }

  @Test func shouldGoBackToTheDefaultWhenCleared() async throws {
    let stores = try await Self.stores([ExpenseCategoryRecord(key: Self.groceries, label: "Groceries", essential: false)])
    _ = try await Self.set(Self.groceries, nil, in: stores)
    #expect(try await Self.essentials(in: stores).essential(Self.groceries) == .byDefault(true))
    #expect(try await Self.records(in: stores).first?.essential == nil)
  }

  @Test func shouldWriteNothingWhenTheChoiceIsAlreadyRecorded() async throws {
    let stores = try await Self.stores([ExpenseCategoryRecord(key: Self.food, label: "Food", essential: true)])
    let logged = try await stores.main.pendingChanges(limit: Int.max).count
    #expect(try await Self.set(Self.food, true, in: stores) == nil)
    #expect(try await Self.set(Self.groceries, nil, in: stores) == nil, "clearing a choice never made writes no record")
    #expect(try await stores.main.pendingChanges(limit: Int.max).count == logged)
    #expect(try await Self.records(in: stores).count == 1)
  }
}
