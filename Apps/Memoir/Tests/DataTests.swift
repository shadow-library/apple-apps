import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import Testing

@testable import Memoir

@MainActor
@Suite("MemoirExporter", TestTimeLimit.standard)
struct MemoirExporterTests {
  @Test("should export every class's records exactly as stored, and read back the same file")
  func exportsEveryClassExactly() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    let fill = try await world.fill(opened)

    let file = try await MemoirExporter.file(of: opened.stores, at: Date(timeIntervalSince1970: 0), appVersion: "1 (2)", receiptImages: [])
    let decoded = try JSONDecoder().decode(MemoirExportFile.self, from: try MemoirExporter.encode(file))

    #expect(decoded == file)
    #expect(file.format == "com.shadow.apps.memoir.export" && file.version == 2)
    #expect(file.generatedAt == "1970-01-01T00:00:00.000Z")
    #expect(file.stores.map(\.name) == ["main", "activity", "health"])
    let expense = try #require(entries(of: "mm_expense", in: decoded).first { $0.key == fill.expense.uuidString.lowercased() })
    #expect(expense.fields?["amount_minor"] == .int(DataWorld.amountMinor))
    #expect(entries(of: "mm_metric_day_activity", in: decoded).map { $0.fields?["entry"]?["value"] } == [.string(DataWorld.steps)])
    #expect(entries(of: "mm_weight", in: decoded).map { $0.fields?["kilograms"] } == [.string(DataWorld.kilograms)])
    #expect(store("health", in: decoded)?.kinds.contains { $0.kind == "mm_weight" && $0.syncClass == "health" } == true)
    #expect(!entries(of: "mm_command", in: decoded).isEmpty, "the command log is exported")
    let removed = try #require(entries(of: "mm_expense", in: decoded).first { $0.key == fill.removedExpense.uuidString.lowercased() })
    #expect(removed.fields?["removed"] == .bool(true), "a removed record is exported with its flag")
    let journal = try #require(entries(of: "mm_journal_entry", in: decoded).first { $0.key == fill.journal.uuidString.lowercased() })
    let head = try #require(journal.revisions?.first { $0.id == journal.head })
    #expect(head.body["text"] == .string(DataWorld.journalText), "a journal entry carries its head revision's text")
    #expect(
      decoded.local.weeklyReviews == [
        MemoirExportFile.WeeklyReview(week: DataWorld.day.isoString, answers: ["better": "Slept before midnight"], completedAtMillis: 7)
      ])
    #expect(decoded.stores.allSatisfy { $0.kinds.allSatisfy { !$0.kind.hasPrefix("_") } }, "sync's bookkeeping is left out")
    #expect(decoded.derived?.note == MemoirExporter.derivedNote)
    for kind in MemoirStoreKind.allCases {
      let section = try #require(store(MemoirExporter.storeName(kind), in: decoded))
      try await expectMatches(section, opened.stores.store(kind))
    }
  }

  @Test("should zip the file with the receipt images this device holds and list the ones it lacks")
  func archivesWithImages() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    let fill = try await world.fill(opened)

    let first = try await MemoirExporter.archive(of: opened.stores, at: Date(), appVersion: "1", into: world.exports)
    let archive = try await MemoirExporter.archive(of: opened.stores, at: Date(), appVersion: "1", into: world.exports)

    let bytes = try Data(contentsOf: archive.url)
    #expect(bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]), "a zip archive")
    let names = String(decoding: bytes, as: UTF8.self)
    #expect(names.contains("memoir-export.json"))
    #expect(names.contains("receipts/\(fill.heldBlob.description).jpeg"))
    #expect(archive.missingImages == 1)
    #expect(archive.url.pathExtension == "zip")
    let waiting = try FileManager.default.contentsOfDirectory(at: world.exports.directory, includingPropertiesForKeys: nil)
    #expect(waiting.map(\.lastPathComponent) == [archive.fileName], "one archive waits at a time and the working folder is gone")
    #expect(first.url == archive.url)
  }

  private func store(_ name: String, in file: MemoirExportFile) -> MemoirExportFile.Store? {
    file.stores.first { $0.name == name }
  }

  private func entries(of kind: String, in file: MemoirExportFile) -> [MemoirExportFile.Entry] {
    file.stores.flatMap(\.kinds).filter { $0.kind == kind }.flatMap(\.entries)
  }

  private func expectMatches(_ section: MemoirExportFile.Store, _ store: VaultStore) async throws {
    for kind in section.kinds {
      let entityKind = try #require(EntityKind(kind.kind))
      let states = try await store.read { transaction in try transaction.states(ofKind: entityKind, scope: .vault) }
      #expect(states.count == kind.entries.count)
      for (ref, state) in states {
        let entry = try #require(kind.entries.first { $0.key == ref.key.rawValue })
        switch state {
        case .record(let record): #expect(entry.fields == Dictionary(uniqueKeysWithValues: record.fields.map { ($0.key.value, $0.value.value) }))
        case .appended(let appended): #expect(entry.item == appended.item)
        case .revisioned(let document): #expect(entry.head == document.headRevision)
        case .purged: Issue.record("a purged entity was exported")
        }
      }
    }
  }
}

@MainActor
@Suite("ExportModel", TestTimeLimit.standard)
struct ExportModelTests {
  @Test("should count what the export covers, prepare an archive and clear it")
  func preparesAndClears() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    try await world.fill(opened)
    let model = ExportModel(context: MemoirScreenContext(opened), exports: world.exports, appVersion: "1")

    await model.load()
    guard case .loaded(let contents) = model.contents else {
      Issue.record("the contents were not counted")
      return
    }
    #expect(contents.count(.expenses) == 1, "the removed expense is not counted")
    #expect(contents.count(.weights) == 1 && contents.count(.metricDays) == 1 && contents.count(.receipts) == 2)

    await model.prepare()
    let url = try #require(model.file?.url)
    #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

    model.clear()
    #expect(model.stage == .idle && model.file == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
  }

  @Test("should remove the waiting archive when the screen goes, including one that finishes after it went")
  func removesTheArchiveOnLeaving() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    let model = ExportModel(context: MemoirScreenContext(opened), exports: world.exports, appVersion: "1")
    await model.prepare()
    let url = try #require(model.file?.url)

    model.disappeared()
    #expect(model.stage == .idle)
    #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

    await model.prepare()
    #expect(model.stage == .idle, "prepared while the screen was gone")
    #expect(!FileManager.default.fileExists(atPath: world.exports.directory.path(percentEncoded: false)))

    model.appeared()
    await model.prepare()
    #expect(model.file != nil)
  }

  @Test("should report an archive that could not be written and change nothing")
  func reportsAFailedArchive() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    try await world.fill(opened)
    let blocker = world.directory.appending(path: "blocker")
    try Data().write(to: blocker)
    let model = ExportModel(context: MemoirScreenContext(opened), exports: MemoirExports(directory: blocker.appending(path: "Exports")), appVersion: "1")

    await model.prepare()

    guard case .failed(let error) = model.stage else {
      Issue.record("expected a failure, got \(model.stage)")
      return
    }
    #expect(error.detail == "memoir_export.file")
    #expect(try await opened.stores.main.read { transaction in try ExpenseRecord.listing(in: transaction).entries.count } == 2)
  }
}

@MainActor
@Suite("MemoirVaultDeletion", TestTimeLimit.standard)
struct MemoirVaultDeletionTests {
  @Test("should stop sync, withdraw reminders, erase the stores, blobs, local tables and defaults, and open an empty vault that needs onboarding")
  func deletesEverythingOnThisDevice() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    let fill = try await world.fill(opened)
    try await world.attach(opened)
    let blobFile = try #require(try await VaultBlobs(store: opened.stores.main).localURL(of: fill.heldBlob))
    let ours = Reminder.identifierPrefix
    world.notifications.foreign = ["\(ours)pending", "other.app.pending"]
    world.notifications.delivered = ["\(ours)delivered": [:], "other.app.delivered": [:]]
    for key in ["weight-unit", "hero.coming-back-dismissed-on", "reminders.on-this-device", "health.read-metrics", "ai.settings.v1", "sync.recovery-recipient.v"] {
      world.defaults.set("x", forKey: "com.shadow.apps.memoir.\(key)")
    }
    world.defaults.set("x", forKey: "other.app.key")
    world.rates.setFetching(false)
    _ = try await MemoirExporter.archive(of: opened.stores, at: Date(), appVersion: "1", into: world.exports)
    let uploaded = try await world.storage.listAll(prefix: "").count

    let deletion = world.deletion()
    try await deletion.delete()

    #expect(deletion.notice == .erased)
    let reopened = try #require(world.vault.opened)
    #expect(reopened.stores.main !== opened.stores.main)
    #expect(try await reopened.stores.main.read { transaction in try ExpenseRecord.listing(in: transaction).entries }.isEmpty)
    #expect(try await reopened.stores.restricted.loadState(.vault).isEmpty, "no weight is left")
    #expect(try await reopened.stores.activity.loadState(.vault).isEmpty, "no steps are left")
    #expect(try await reopened.stores.main.read { transaction in try WeeklyReviewAnswers.answers(week: DataWorld.day, in: transaction) } == ReviewAnswers.none)
    #expect(!FileManager.default.fileExists(atPath: blobFile.path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: world.exports.directory.path(percentEncoded: false)))

    #expect(try world.locations.load() == .turnedOff(.disconnected), "a later launch never attaches the old location on its own")
    try await MemoirSyncWorld.until("sync is off for the new vault") { world.runtimes.status == .off && world.runtimes.syncingRoutes.isEmpty }
    #expect(try await world.storage.listAll(prefix: "").count == uploaded, "what sync sent stays at the location")

    try await MemoirSyncWorld.until("the reminders are withdrawn") {
      world.notifications.foreign == ["other.app.pending"] && Set(world.notifications.delivered.keys) == ["other.app.delivered"]
    }
    let kept = world.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("com.shadow.apps.memoir.") || $0 == "other.app.key" }.sorted()
    #expect(kept == ["com.shadow.apps.memoir.ai.settings.v1", "com.shadow.apps.memoir.sync.recovery-recipient.v", "other.app.key"])
    #expect(world.rates.isFetching, "\"Fetch exchange rates\" is back to its default with the cleared defaults")

    let gate = OnboardingGate()
    let task = Task { await gate.run(stores: reopened.stores) }
    defer { task.cancel() }
    try await MemoirSyncWorld.until("the gate's first read") { gate.state != .checking }
    #expect(gate.state == .needed)
    await world.runtimes.shutDown()
  }

  @Test("should erase nothing when sync cannot be turned off")
  func keepsEverythingWhenSyncStays() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    let fill = try await world.fill(opened)
    try await world.attach(opened)
    let blobFile = try #require(try await VaultBlobs(store: opened.stores.main).localURL(of: fill.heldBlob))
    world.notifications.delivered = ["\(Reminder.identifierPrefix)delivered": [:]]
    world.defaults.set("x", forKey: "com.shadow.apps.memoir.weight-unit")
    let attached = try world.locations.load()
    try world.lock("Sync")
    let deletion = world.deletion()

    await #expect(throws: VaultDeletionError.self) { try await deletion.delete() }

    #expect(world.vault.opened?.stores.main === opened.stores.main)
    #expect(try await opened.stores.main.read { transaction in try ExpenseRecord.listing(in: transaction).entries.count } == 2)
    #expect(try await !opened.stores.restricted.loadState(.vault).isEmpty)
    #expect(FileManager.default.fileExists(atPath: blobFile.path(percentEncoded: false)))
    #expect(try await opened.stores.main.read { transaction in try WeeklyReviewAnswers.answers(week: DataWorld.day, in: transaction) }.isComplete)
    #expect(world.defaults.string(forKey: "com.shadow.apps.memoir.weight-unit") == "x")
    #expect(Set(world.notifications.delivered.keys) == ["\(Reminder.identifierPrefix)delivered"])
    #expect(try world.locations.load() == attached)
    #expect(world.runtimes.runtime != nil && world.runtimes.syncingRoutes.count == 2, "sync goes on")
    #expect(deletion.notice == nil && world.vaultChanges == 0)
    await world.runtimes.shutDown()
  }

  @Test("should say the deletion is incomplete when a store directory stays, and still open the vault and forget the defaults")
  func reportsAnIncompleteErasure() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    try await world.fill(opened)
    world.defaults.set("x", forKey: "com.shadow.apps.memoir.weight-unit")
    try world.lock("Vaults")
    let deletion = world.deletion()

    try await deletion.delete()

    #expect(deletion.notice == .incomplete(code: "memoir_deletion.erase_failed"))
    let reopened = try #require(world.vault.opened)
    #expect(reopened.stores.main !== opened.stores.main)
    #expect(world.vaultChanges == 1)
    #expect(world.defaults.object(forKey: "com.shadow.apps.memoir.weight-unit") == nil)
  }

  @Test("should report the outcome once the vault has closed and run the app's vault change")
  func reportsTheOutcome() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    _ = try await world.open()
    let deletion = world.deletion()

    try await deletion.delete()

    #expect(deletion.notice == .erased)
    #expect(world.vaultChanges == 1)
  }

  @Test("should erase nothing when the vault is not open or its location cannot be named")
  func refusesWithoutTouchingAnything() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    world.defaults.set("x", forKey: "com.shadow.apps.memoir.weight-unit")

    await #expect(throws: VaultDeletionError.notOpen) { try await world.deletion().delete() }

    let opened = try await world.open()
    try await world.fill(opened)
    let deletion = world.deletion { () throws(MemoirVaultOpenError) -> MemoirVaultLocation in throw .locationUnavailable("no support directory") }
    await #expect(throws: VaultDeletionError.locationUnavailable("memoir_vault.location_unavailable")) { try await deletion.delete() }

    #expect(world.vault.opened?.stores.main === opened.stores.main)
    #expect(try await opened.stores.main.read { transaction in try ExpenseRecord.listing(in: transaction).entries.count } == 2)
    #expect(world.defaults.string(forKey: "com.shadow.apps.memoir.weight-unit") == "x")
    #expect(deletion.notice == nil)
  }
}

@MainActor
@Suite("DeleteVaultModel", TestTimeLimit.quick)
struct DeleteVaultModelTests {
  private func model() throws -> DeleteVaultModel {
    DeleteVaultModel(context: try MemoirScreenContext.inMemory())
  }

  @Test("should reach the last question only with both statements ticked and the word typed")
  func confirmsStepByStep() throws {
    let model = try model()

    model.setAcknowledged(.permanent, true)
    model.continueToConfirmation()
    #expect(model.stage == .acknowledging)

    model.setAcknowledged(.exported, true)
    model.continueToConfirmation()
    #expect(model.stage == .confirming)

    model.typed = "delete"
    model.askToDelete()
    #expect(!model.isAskingToDelete)

    model.typed = " DELETE "
    model.askToDelete()
    #expect(model.isAskingToDelete)
  }

  @Test("should delete nothing when the last question is answered with Keep my data or the flow is stopped")
  func cancelledConfirmationDeletesNothing() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    try await world.fill(opened)
    let model = DeleteVaultModel(context: MemoirScreenContext(opened))
    let deletion = world.deletion()
    model.setAcknowledged(.permanent, true)
    model.setAcknowledged(.exported, true)
    model.continueToConfirmation()
    model.typed = "DELETE"
    model.askToDelete()

    model.isAskingToDelete = false
    model.askToStop()
    model.stop()
    await model.delete { () throws(VaultDeletionError) in try await deletion.delete() }

    #expect(model.stage == .acknowledging && model.stopped)
    #expect(model.acknowledged.isEmpty && model.typed.isEmpty)
    #expect(world.vault.opened?.stores.main === opened.stores.main)
    #expect(try await opened.stores.main.read { transaction in try ExpenseRecord.listing(in: transaction).entries.count } == 2)
    #expect(world.vaultChanges == 0 && deletion.notice == nil)
  }

  @Test("should bring the confirmation back with the reason when the deletion erased nothing")
  func showsARefusal() async throws {
    let model = try model()
    model.setAcknowledged(.permanent, true)
    model.setAcknowledged(.exported, true)
    model.continueToConfirmation()
    model.typed = "DELETE"
    var calls = 0

    await model.delete { () throws(VaultDeletionError) in
      calls += 1
      throw .syncNotStopped(.deviceLocked)
    }

    #expect(calls == 1)
    #expect(model.stage == .confirming)
    #expect(model.failure?.detail == SyncStartupError.deviceLocked.code)
  }
}

@Suite("MemoirDeviceDefaults", TestTimeLimit.quick)
struct MemoirDeviceDefaultsTests {
  @Test("should remove Memoir's own keys and keep the shell's AI and sync keys and other apps' keys")
  func forgetsOnlyMemoirKeys() throws {
    let suite = "MemoirDeviceDefaultsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    for key in ["com.shadow.apps.memoir.weight-unit", "com.shadow.apps.memoir.ai.settings.v1", "com.shadow.apps.memoir.sync.recovery-offer-declined.v", "other"] {
      defaults.set(true, forKey: key)
    }

    let removed = MemoirDeviceDefaults(defaults: defaults).forget()

    #expect(removed == ["com.shadow.apps.memoir.weight-unit"])
    #expect(defaults.object(forKey: "com.shadow.apps.memoir.ai.settings.v1") != nil)
    #expect(defaults.object(forKey: "com.shadow.apps.memoir.sync.recovery-offer-declined.v") != nil)
    #expect(defaults.object(forKey: "other") != nil)
  }
}
