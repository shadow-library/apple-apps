import Foundation
import ShadowCore
import ShadowStore
import ShadowSync
import Testing

@testable import MemoirCore

@Suite("MemoirSchema", TestTimeLimit.quick)
struct MemoirSchemaTests {
  private static let frozen: [(store: MemoirStoreKind, path: String, version: Int)] = [
    (.main, "schema/registry-v1.json", 1), (.activity, "schema/activity-registry-v1.json", 1), (.restricted, "schema/restricted-registry-v1.json", 1),
  ]

  @Test func shouldMatchTheFrozenRegistryDescriptions() throws {
    for (store, path, version) in Self.frozen where store.registry.version == version {
      #expect(
        store.registry.canonicalDescription() == (try MemoirStoreFixture.fixture(path)),
        """
        The \(store.rawValue) registry no longer matches Fixtures/\(path). A synced kind's shape, a field's rule or a retention limit never changes once shipped, \
        and a kind or field is never removed. To add kinds or fields, raise the store's version in MemoirSchema, save the new canonical description beside v1 \
        and add it to this list.
        """)
    }
  }

  @Test func shouldStayCompatibleWithEveryFrozenRegistry() throws {
    for (store, path, version) in Self.frozen {
      let frozen = try SchemaRegistry(canonicalDescription: try MemoirStoreFixture.fixture(path))
      #expect(frozen.version == version)
      #expect(store.registry.incompatibilities(with: frozen) == [], "the \(store.rawValue) registry cannot carry version \(version) additively")
    }
  }

  @Test func shouldDeclareEveryKindInExactlyTheStoreOfItsClass() throws {
    for kind in MemoirKind.allCases {
      #expect(kind.rawValue.hasPrefix("mm_"))
      let declaring = MemoirStoreKind.allCases.filter { $0.registry[kind.entityKind] != nil }
      #expect(declaring.map(\.syncClass) == [kind.syncClass], "\(kind.rawValue) is declared in \(declaring)")
      for store in declaring { #expect(store.registry[kind.entityKind]?.syncClass == kind.syncClass) }
    }
    let mainClasses = Set(MemoirSchema.entities(of: .main).map(\.syncClass))
    #expect(mainClasses == [.general])
    #expect(MemoirStoreKind.restricted.kinds == [.healthMetric, .healthMetricDay, .weight])
    #expect(MemoirStoreKind.activity.kinds == [.activityMetric, .activityMetricDay])
  }

  @Test func shouldRefuseAHealthKindDeclaredInTheMainStore() throws {
    let weight = try #require(MemoirSchema.restrictedRegistry[MemoirKind.weight.entityKind])
    let registry = SyncKernelSchema.registry(version: MemoirSchema.mainVersion + 1, adding: MemoirSchema.entities(of: .main) + [weight])
    #expect(throws: StoreError.self) { try VaultStore.open(.inMemory, registry: registry, admittedClasses: [.general]) }
    do {
      _ = try VaultStore.open(.inMemory, registry: registry, admittedClasses: [.general])
    } catch {
      guard case .syncClassNotAdmitted(let kind, let syncClass) = error else { throw MemoirFixtureError(description: "unexpected \(error)") }
      #expect(kind == MemoirKind.weight.entityKind)
      #expect(syncClass == .health)
    }
  }

  @Test func shouldRefuseAWriteOfAKindTheStoreDoesNotDeclare() async throws {
    let main = try MemoirStore.openInMemory(.main)
    let activity = try MemoirStore.openInMemory(.activity)
    let restricted = try MemoirStore.openInMemory(.restricted)
    let weight = WeightRecord(date: try MemoirStoreFixture.date("2026-11-20"), kilograms: try MemoirStoreFixture.decimal("72.4"), loggedAtMillis: 1)
    let quest = QuestRecord(id: MemoirStoreFixture.quest, name: "Run")
    let heartRate = MetricDayRecord<HealthMetric>(
      metric: MetricID(recordUUID: MemoirStoreFixture.metric), date: try MemoirStoreFixture.date("2026-11-20"), value: try MemoirStoreFixture.decimal("61"), source: .known(.health)
    )
    await #expect(throws: StoreError.self) { try await main.write { transaction in try weight.create(in: &transaction) } }
    await #expect(throws: StoreError.self) { try await activity.write { transaction in try heartRate.create(in: &transaction) } }
    await #expect(throws: StoreError.self) { try await restricted.write { transaction in try quest.create(in: &transaction) } }
    #expect(try await main.pendingChanges(limit: 10).isEmpty)
    _ = try await restricted.write { transaction in try weight.create(in: &transaction) }
    _ = try await restricted.write { transaction in try heartRate.create(in: &transaction) }
    _ = try await main.write { transaction in try quest.create(in: &transaction) }
  }

  @Test func shouldRefuseAFieldOutsideAKind() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let ref = QuestRecord.ref(MemoirStoreFixture.quest)
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in try transaction.set(ref, ["name": "Run", "strictness": "anchor"]) }
    }
    #expect(try await store.read { transaction in try transaction.state(of: ref) } == nil)
  }

  @Test func shouldPinTheNaturalKeyHashes() throws {
    let date = try MemoirStoreFixture.date("2026-11-20")
    let keys: [(MemoirKey, String)] = [
      (.expenseCategory(try MemoirStoreFixture.category("groceries")), "n:256236f8f245be80996f98b6e1f533715286dfb4"),
      (.fxRate(base: try MemoirStoreFixture.currency("JPY"), quote: try MemoirStoreFixture.currency("EUR"), date: date), "n:bbeac7a6169ed7a704a56841379964e107462a77"),
      (.metricDay(.general, metric: MemoirStoreFixture.metric, date: date), "n:9242faea94179c49a50d70aeaed3d64da09971f9"),
      (.metricDay(.activity, metric: MemoirStoreFixture.metric, date: date), "n:f2f3e08d96e53bdc5c6af8093d14351214d30623"),
      (.metricDay(.health, metric: MemoirStoreFixture.metric, date: date), "n:4c994bfe7b8ecb1821a5dbedbd19b90eaf78c611"),
      (.weight(date), "n:1a3df681100da0e1e630378496b6ba978e3b5e9e"),
      (.accountSettings, "n:e6b97cc7ab9e3c985780d7bba26e604befd06c44"),
    ]
    for (key, pinned) in keys {
      #expect(key.ref.key.rawValue == pinned, "\(key.kind.rawValue) hashes its components differently; never reorder or rename them")
      #expect(try MemoirKey(stored: key.stored, of: key.ref) == key)
    }
  }

  @Test func shouldRefuseAStoredNaturalKeyThatDoesNotHashToItsRef() throws {
    let date = try MemoirStoreFixture.date("2026-11-20")
    let ref = MemoirKey.weight(date).ref
    #expect(throws: MemoirUnreadable.keyMismatch(ref)) { try MemoirKey(stored: MemoirKey.weight(try MemoirStoreFixture.date("2026-11-21")).stored, of: ref) }
    #expect(throws: MemoirUnreadable.invalid(field: "natural_key")) { try MemoirKey(stored: ["date": "2026-11-20", "extra": "x"], of: ref) }
    #expect(throws: MemoirUnreadable.identity(QuestRecord.ref(MemoirStoreFixture.quest))) {
      try MemoirKey(stored: [:], of: QuestRecord.ref(MemoirStoreFixture.quest))
    }
  }
}
