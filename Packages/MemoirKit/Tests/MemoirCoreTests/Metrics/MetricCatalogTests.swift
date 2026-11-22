import Foundation
import ShadowCore
import ShadowStore
import ShadowSync
import Synchronization
import Testing

@testable import MemoirCore

@Suite("MetricCatalog", TestTimeLimit.standard)
struct MetricCatalogTests {
  private static let issuer = CommandIssuer(clock: HealthFixture.utc, wallClock: HealthFixture.wallClock())
  private static let glucose = MetricDefinition(name: "Glucose", unit: "mmol/L", valueType: .number, direction: .range)

  private func commandTypes(_ stores: MemoirStores) async throws -> [String] {
    try await stores.main.read { transaction in try MemoirCommand.listing(in: transaction) }.entries.map(\.record.type.name).sorted()
  }

  @Test func shouldFixTheBuiltinsClassesAndIDs() {
    #expect(BuiltinMetric.allCases.filter { $0.syncClass == .activity } == [.steps, .workoutMinutes])
    #expect(BuiltinMetric.allCases.filter { $0.syncClass == .health } == [.activeEnergy, .weight, .restingHeartRate, .sleep, .waistCircumference, .water])
    #expect(BuiltinMetric.sleep.definition.unit == "min")
    #expect(Set(BuiltinMetric.allCases.map(\.id)).count == BuiltinMetric.allCases.count)
    #expect(BuiltinMetric.steps.id == derivedID("com.shadow.library.memoircore.builtin-metric", "steps"))
    for metric in BuiltinMetric.allCases { #expect(BuiltinMetric(id: metric.id) == metric) }
  }

  @Test func shouldCreateAnOwnersMetricInTheHealthStoreUnlessTheOwnerSaysOtherwise() async throws {
    let stores = try MemoirStores.openInMemory()
    let catalog = MetricCatalog(stores: stores, issuer: CommandIssuerSource { _ in Self.issuer })

    let glucose = try await catalog.create(Self.glucose)
    let pages = try await catalog.create(MetricDefinition(name: "Pages read", valueType: .count, direction: .higher), as: .general)

    #expect(glucose.metricClass == .health && pages.metricClass == .general)
    #expect(try await HealthFixture.entityCount(.healthMetric, in: stores.restricted) == 1)
    #expect(try await HealthFixture.entityCount(.generalMetric, in: stores.main) == 1)
    #expect(try await commandTypes(stores) == ["metric.create", "metric.create"])
    await #expect(throws: MetricsError.self) { try await catalog.create(MetricDefinition(name: "", valueType: .number, direction: .neutral)) }
  }

  @Test func shouldRefuseToChangeOrDeleteABuiltinAndToWriteAnAbsentMetric() async throws {
    let stores = try MemoirStores.openInMemory()
    let catalog = MetricCatalog(stores: stores, issuer: CommandIssuerSource { _ in Self.issuer })
    for attempt in [
      { () async throws(MetricsError) in try await catalog.update(BuiltinMetric.weight.reference, to: Self.glucose) },
      { () async throws(MetricsError) in try await catalog.delete(BuiltinMetric.steps.reference) },
      { () async throws(MetricsError) in _ = try await catalog.reclassify(BuiltinMetric.sleep.reference, as: .general) },
    ] {
      do {
        try await attempt()
        Issue.record("a built-in changed")
      } catch {
        #expect(error.referenceCode == "MET_003")
      }
    }
    let absent = MetricReference(id: UUID(), metricClass: .health)
    do {
      try await catalog.register(HealthFixture.decimal("5"), for: absent, on: HealthFixture.today)
      Issue.record("an absent metric took a value")
    } catch {
      #expect(error.referenceCode == "MET_002")
    }
    do {
      try await catalog.register(HealthFixture.decimal("5"), for: BuiltinMetric.steps.reference, on: HealthFixture.today, source: .questLog)
      Issue.record("a quest-log entry without its occurrence was written")
    } catch {
      guard case .refused(.invalidField(field: "questLogId", problem: .required)) = error else { throw error }
    }
    #expect(try await commandTypes(stores) == [])
    #expect(try await HealthFixture.entityCount(.healthMetricDay, in: stores.restricted) == 0)
  }

  @Test func shouldChangeAClassByCreatingAMetricInTheNewStoreAndRemovingTheOld() async throws {
    let stores = try MemoirStores.openInMemory()
    let catalog = MetricCatalog(stores: stores, issuer: CommandIssuerSource { _ in Self.issuer })
    let glucose = try await catalog.create(Self.glucose)
    try await catalog.register(HealthFixture.decimal("5.4"), for: glucose, on: HealthFixture.today)

    let general = try await catalog.reclassify(glucose, as: .general)

    #expect(general.metricClass == .general && general.id != glucose.id)
    #expect(try await catalog.reclassify(general, as: .general) == general)
    let moved = try await stores.main.read { transaction in try MetricRecord<GeneralMetric>.read(id: MetricID(recordUUID: general.id), in: transaction) }
    #expect(moved.entry?.record.name == "Glucose" && moved.entry?.isRemoved == false)
    let old = try await stores.restricted.read { transaction in try MetricRecord<HealthMetric>.read(id: MetricID(recordUUID: glucose.id), in: transaction) }
    #expect(old.entry?.isRemoved == true)
    #expect(try await HealthFixture.entityCount(.generalMetricDay, in: stores.main) == 0)
    #expect(try await HealthFixture.entityCount(.healthMetricDay, in: stores.restricted) == 1)
    #expect(try await commandTypes(stores) == ["metric.create", "metric.create", "metric.delete"])
    do {
      try await catalog.register(HealthFixture.decimal("5.5"), for: glucose, on: HealthFixture.today)
      Issue.record("a removed metric took a value")
    } catch {
      #expect(error.referenceCode == "MET_002")
    }
  }

  @Test func shouldAppendMetricRegisterOnlyForAGeneralMetric() async throws {
    let stores = try MemoirStores.openInMemory()
    let catalog = MetricCatalog(stores: stores, issuer: CommandIssuerSource { _ in Self.issuer })
    let glucose = try await catalog.create(Self.glucose)
    let pages = try await catalog.create(MetricDefinition(name: "Pages read", valueType: .count, direction: .higher), as: .general)
    let before = try await stores.main.pendingChanges(limit: .max).count

    try await catalog.register(HealthFixture.decimal("5.4"), for: glucose, on: HealthFixture.today)
    try await catalog.register(HealthFixture.decimal("9000"), for: BuiltinMetric.steps.reference, on: HealthFixture.today)
    try await catalog.register(HealthFixture.decimal("70.2"), for: BuiltinMetric.weight.reference, on: HealthFixture.today)
    #expect(try await stores.main.pendingChanges(limit: .max).count == before)
    #expect(try await HealthFixture.entityCount(.healthMetricDay, in: stores.restricted) == 2)
    #expect(try await HealthFixture.entityCount(.activityMetricDay, in: stores.activity) == 1)

    try await catalog.register(HealthFixture.decimal("30"), for: pages, on: HealthFixture.today)
    #expect(try await commandTypes(stores) == ["metric.create", "metric.create", "metric.register"])
    #expect(try await HealthFixture.entityCount(.generalMetricDay, in: stores.main) == 1)
  }

  @Test func shouldKeepAClaimAndAnActivityToggleMadeOnTwoDevicesAtOnce() async throws {
    let phone = try MemoirStores.openInMemory()
    let mac = try MemoirStores.openInMemory()
    _ = try await HealthFixture.claim(HealthFixture.phone, in: phone)
    _ = try await mac.main.write { transaction in try HealthSettings.setActivityOnICloud(true, in: &transaction) }

    try await MemoirStoreFixture.exchange(phone.main, mac.main)

    for stores in [phone, mac] {
      let record = try await stores.main.read { transaction in try HealthSettingsRecord.read(key: .healthSettings, in: transaction) }.entry?.record
      #expect(record?.reader?.device == HealthFixture.phone.id)
      #expect(record?.isActivityOnICloud == true)
    }
    _ = try await phone.main.write { transaction in try HealthSettings.release(HealthFixture.phone, in: &transaction) }
    #expect(try await phone.main.read { transaction in try HealthSettings.designation(in: transaction) } == nil)
    #expect(try await phone.main.read { transaction in try HealthSettings.isActivityOnICloud(in: transaction) })
  }

  @Test func shouldTreatAnUnreadableSettingsRecordAsActivityOff() async throws {
    let stores = try MemoirStores.openInMemory()
    let ref = MemoirKey.healthSettings.ref
    _ = try await stores.main.write { transaction in try transaction.set(ref, ["natural_key": MemoirKey.healthSettings.stored, "activity_on_icloud": "yes"]) }
    #expect(try await stores.main.read { transaction in try HealthSettings.isActivityOnICloud(in: transaction) } == false)
    #expect(try await MemoirSyncRouting.routes(for: .iCloud, settingsIn: stores.main).map(\.store) == [.main])
  }
}

@Suite("QuickLogWriter", TestTimeLimit.standard)
struct QuickLogWriterTests {
  @Test func shouldWriteAWeightToTheRestrictedStoreAndOnlyItsCommandToTheMainStore() async throws {
    let stores = try MemoirStores.openInMemory()
    let writer = QuickLogWriter(stores: stores, issuer: CommandIssuerSource { _ in CommandIssuer(clock: HealthFixture.utc, wallClock: HealthFixture.wallClock()) })
    let day = HealthFixture.today

    guard case .saved = try await writer.saveWeight(HealthFixture.decimal("72.4"), on: day) else { throw MemoirFixtureError(description: "the weight was not saved") }
    let second = try await writer.saveWeight(HealthFixture.decimal("72.9"), on: day)
    guard case .needsConfirmation(let existing) = second else { throw MemoirFixtureError(description: "expected a confirmation, got \(second)") }
    #expect(existing.kilograms == HealthFixture.decimal("72.4"))
    guard case .saved = try await writer.saveWeight(HealthFixture.decimal("72.9"), on: day, confirmedReplacement: true) else {
      throw MemoirFixtureError(description: "the confirmed weight was not saved")
    }

    let weight = try await stores.restricted.read { transaction in try WeightRecord.read(key: .weight(day), in: transaction) }
    #expect(weight.entry?.record.kilograms == HealthFixture.decimal("72.9"))
    #expect(try await HealthFixture.entityCount(.command, in: stores.main) == 2)
    await #expect(throws: QuickLogError.self) { try await writer.saveWeight(HealthFixture.decimal("0"), on: day) }
    #expect(try await HealthFixture.entityCount(.command, in: stores.main) == 2)
  }

  /// A weight whose `weight.save` never reached the main store (the write between the two failed) was never counted, so saving the day again replaces it
  /// as a first save rather than asking to replace a weight the owner was told was not saved.
  @Test func shouldReplaceAWeightNoCommandNamesWithoutAskingAndAppendItsCommand() async throws {
    let stores = try MemoirStores.openInMemory()
    let writer = QuickLogWriter(stores: stores, issuer: CommandIssuerSource { _ in CommandIssuer(clock: HealthFixture.utc, wallClock: HealthFixture.wallClock()) })
    let day = HealthFixture.today
    let other = try #require(day.adding(days: -1))
    _ = try await stores.restricted.write { transaction in
      try WeightRecord(date: day, kilograms: HealthFixture.decimal("70.1"), loggedAtMillis: 1).create(in: &transaction)
    }
    guard case .saved = try await writer.saveWeight(HealthFixture.decimal("74"), on: other) else { throw MemoirFixtureError(description: "the weight was not saved") }

    let saved = try await writer.saveWeight(HealthFixture.decimal("72.4"), on: day)

    guard case .saved(let command) = saved else { throw MemoirFixtureError(description: "expected the orphan to be replaced, got \(saved)") }
    #expect(try MemoirCommandBody(command) == .weightSave(WeightEntry(date: day)))
    let weight = try await stores.restricted.read { transaction in try WeightRecord.read(key: .weight(day), in: transaction) }
    #expect(weight.entry?.record.kilograms == HealthFixture.decimal("72.4"))
    #expect(weight.entry?.record.loggedAtMillis == command.instantMillis)
    #expect(try await HealthFixture.entityCount(.command, in: stores.main) == 2)
    let again = try await writer.saveWeight(HealthFixture.decimal("72.9"), on: day)
    guard case .needsConfirmation(let existing) = again else { throw MemoirFixtureError(description: "a counted weight must ask, got \(again)") }
    #expect(existing.kilograms == HealthFixture.decimal("72.4"))
  }

  /// Restricted data syncs in its own store, so another device's weight can arrive before its `weight.save`: it is asked about, never overwritten.
  @Test func shouldAskBeforeReplacingAWeightAnotherDeviceWroteLast() async throws {
    let stores = try MemoirStores.openInMemory()
    let other = try MemoirStores.openInMemory()
    let writer = QuickLogWriter(stores: stores, issuer: CommandIssuerSource { _ in CommandIssuer(clock: HealthFixture.utc, wallClock: HealthFixture.wallClock()) })
    let day = HealthFixture.today
    let theirs = WeightRecord(date: day, kilograms: HealthFixture.decimal("70.1"), loggedAtMillis: 1)
    _ = try await other.restricted.write { transaction in try theirs.create(in: &transaction) }
    try await MemoirStoreFixture.exchange(stores.restricted, other.restricted)

    let saved = try await writer.saveWeight(HealthFixture.decimal("72.4"), on: day)

    #expect(saved == .needsConfirmation(existing: theirs))
    #expect(try await HealthFixture.entityCount(.command, in: stores.main) == 0)
  }

  /// A `weight.save` this version cannot read may name the day, so an orphan-looking record is asked about.
  @Test func shouldAskWhenAWeightSaveCannotBeRead() async throws {
    let stores = try MemoirStores.openInMemory()
    let issuer = CommandIssuer(clock: HealthFixture.utc, wallClock: HealthFixture.wallClock())
    let writer = QuickLogWriter(stores: stores, issuer: CommandIssuerSource { _ in issuer })
    let day = HealthFixture.today
    let orphan = WeightRecord(date: day, kilograms: HealthFixture.decimal("70.1"), loggedAtMillis: 1)
    _ = try await stores.restricted.write { transaction in try orphan.create(in: &transaction) }
    let newer = try issuer.command(.weightSave(WeightEntry(date: day)))
    var payload = newer.payload.members
    payload["scale"] = "kitchen"
    let item = newer.members.values.merging(["payload": .object(payload)]) { $1 }
    _ = try await stores.main.write { transaction in try transaction.append(MemoirCommand.ref(newer.id), item: item) }
    #expect(try await stores.main.read { transaction in try MemoirCommand.listing(in: transaction) }.unreadable == 1)

    let saved = try await writer.saveWeight(HealthFixture.decimal("72.4"), on: day)

    #expect(saved == .needsConfirmation(existing: orphan))
    #expect(try await stores.restricted.read { transaction in try WeightRecord.read(key: .weight(day), in: transaction) }.entry?.record == orphan)
  }

  @Test func shouldWriteAGeneralQuickLogAndItsCommandInOneMainStoreWrite() async throws {
    let stores = try MemoirStores.openInMemory()
    let writer = QuickLogWriter(stores: stores, issuer: CommandIssuerSource { _ in CommandIssuer(clock: HealthFixture.utc, wallClock: HealthFixture.wallClock()) })
    let id = UUID()
    let side = SideQuestRecord(id: id, date: HealthFixture.today, name: "Fixed the bike", loggedAtMillis: 1)

    try await writer.log(side, as: .sideQuestLog(SideQuestEntry(id: id, date: HealthFixture.today)))
    await #expect(throws: QuickLogError.self) {
      try await writer.log(
        SideQuestRecord(id: UUID(), date: HealthFixture.today, name: "", loggedAtMillis: 1), as: .sideQuestLog(SideQuestEntry(id: id, date: HealthFixture.today)))
    }

    #expect(try await HealthFixture.entityCount(.sideQuest, in: stores.main) == 1)
    #expect(try await HealthFixture.entityCount(.command, in: stores.main) == 1)
  }

  /// A writer kept on a screen must stamp each command with the clock the main store gives when the command is written, not when the writer was built.
  @Test func shouldTakeEachCommandsIssuerFromTheMainStoreWhenItIsWritten() async throws {
    let stores = try MemoirStores.openInMemory()
    let offset = Mutex(60)
    let seen = Mutex([Int]())
    let source = CommandIssuerSource { transaction in
      let count = try MemoirCommand.listing(in: transaction).entries.count
      seen.withLock { $0.append(count) }
      return CommandIssuer(clock: IssueClock(fixedOffsetMinutes: offset.withLock { $0 })!, wallClock: HealthFixture.wallClock())
    }
    let writer = QuickLogWriter(stores: stores, issuer: source)
    let catalog = MetricCatalog(stores: stores, issuer: source)
    let id = UUID()

    let first = try await writer.log(
      SideQuestRecord(id: id, date: HealthFixture.today, name: "Fixed the bike", loggedAtMillis: 1), as: .sideQuestLog(SideQuestEntry(id: id, date: HealthFixture.today)))
    offset.withLock { $0 = 540 }
    guard case .saved(let weight) = try await writer.saveWeight(HealthFixture.decimal("72.4"), on: HealthFixture.today) else {
      throw MemoirFixtureError(description: "the weight was not saved")
    }
    offset.withLock { $0 = -300 }
    try await catalog.register(
      HealthFixture.decimal("12"), for: try await catalog.create(MetricDefinition(name: "Pages read", valueType: .count, direction: .higher), as: .general), on: HealthFixture.today
    )

    let offsets = try await stores.main.read { transaction in try MemoirCommand.listing(in: transaction) }.entries.map(\.record.utcOffsetMinutes)
    #expect(first.utcOffsetMinutes == 60 && weight.utcOffsetMinutes == 540)
    #expect(offsets.sorted() == [-300, -300, 60, 540])
    #expect(seen.withLock { $0 } == [0, 1, 2, 3], "each command's issuer is read from the main store as it stands")
  }

  @Test func shouldWriteNothingWhenTheIssuerCannotBeResolved() async throws {
    struct Unresolved: Error {}
    let stores = try MemoirStores.openInMemory()
    let writer = QuickLogWriter(stores: stores, issuer: CommandIssuerSource { _ in throw Unresolved() })
    let id = UUID()

    await #expect(throws: QuickLogError.self) {
      try await writer.log(
        SideQuestRecord(id: id, date: HealthFixture.today, name: "Fixed the bike", loggedAtMillis: 1), as: .sideQuestLog(SideQuestEntry(id: id, date: HealthFixture.today)))
    }
    await #expect(throws: QuickLogError.self) { try await writer.saveWeight(HealthFixture.decimal("72.4"), on: HealthFixture.today) }

    #expect(try await HealthFixture.entityCount(.sideQuest, in: stores.main) == 0)
    #expect(try await HealthFixture.entityCount(.command, in: stores.main) == 0)
    #expect(try await stores.restricted.read { transaction in try WeightRecord.read(key: .weight(HealthFixture.today), in: transaction) } == .absent)
  }
}
