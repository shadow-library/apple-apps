import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("MemoirModules", TestTimeLimit.standard)
struct MemoirModulesTests {
  private func following(_ stores: MemoirStores) async throws -> (MemoirModules, Task<Void, Never>) {
    let modules = MemoirModules()
    let task = Task { await modules.run(stores: stores) }
    try await until("the first read") { modules.standing != .reading }
    return (modules, task)
  }

  @Test("should show every module for a vault without a settings record")
  func shouldShowEveryModuleWithoutRecord() async throws {
    let world = try await SettingsWorld(currency: nil)
    defer { world.stop() }
    let (modules, task) = try await following(world.context.stores)
    defer { task.cancel() }

    #expect(modules.standing == .read(.all))
    #expect(modules.shows(.destination(.today)))
  }

  @Test("should read the record's modules and follow each change to them")
  func shouldFollowModuleChanges() async throws {
    let world = try await SettingsWorld(currency: nil)
    defer { world.stop() }
    let euro = try #require(CurrencyCode("EUR"))
    try await world.context.writer.write { _, transaction in
      _ = try AccountSettingsRecord(
        defaultCurrency: euro, enabledCurrencies: [euro], moduleHero: false, moduleQuests: false, moduleJournal: false, moduleMeals: false, moduleBody: false
      ).create(in: &transaction)
    }
    let (modules, task) = try await following(world.context.stores)
    defer { task.cancel() }

    #expect(modules.selection == (try ModuleSelection([.money])))
    #expect(!modules.shows(.destination(.today)))
    #expect(!modules.shows(.quest(.new)))
    #expect(modules.shows(.money(.categories)))

    try await world.context.writer.write { _, transaction in
      _ = try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { record in record.setModule(.journal, enabled: true) }
    }
    try await until("the journal module") { modules.selection.contains(.journal) }

    #expect(modules.selection == (try ModuleSelection([.money, .journal])))
  }

  @Test("should read a merge that breaks the laws as MemoirCore makes it valid")
  func shouldReadMergedSelectionAsCoreDoes() async throws {
    let world = try await SettingsWorld(currency: nil)
    defer { world.stop() }
    let euro = try #require(CurrencyCode("EUR"))
    try await world.context.writer.write { _, transaction in
      _ = try AccountSettingsRecord(
        defaultCurrency: euro, enabledCurrencies: [euro], moduleHero: false, moduleQuests: true, moduleMoney: false, moduleJournal: false, moduleMeals: false,
        moduleBody: false
      ).create(in: &transaction)
    }
    let (modules, task) = try await following(world.context.stores)
    defer { task.cancel() }

    #expect(modules.selection == (try ModuleSelection([.quests, .hero])))
  }

  @Test("should show every module in the demo, whose seeded record turns none off")
  func shouldShowEveryModuleInDemo() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "MemoirModulesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = MemoirDemoEnvironment.session(directory: { root.appending(path: DemoDirectory.name, directoryHint: .isDirectory) }, pace: .zero)
    await session.enter()
    let opened = try #require(session.active?.vault.opened)
    let (modules, task) = try await following(opened.stores)

    #expect(try await opened.stores.main.read { transaction in try AccountSettingsRecord.read(key: .accountSettings, in: transaction).entry?.record } != nil)
    #expect(modules.standing == .read(.all))
    task.cancel()
    await session.leave()
  }

  @Test("should show every module when the first read fails")
  func shouldShowEveryModuleWhenReadFails() async throws {
    let world = try await SettingsWorld(currency: nil)
    defer { world.stop() }
    try world.context.stores.main.close()
    let (modules, task) = try await following(world.context.stores)
    defer { task.cancel() }

    #expect(modules.standing == .read(.all))
    for destination in MemoirDestination.allCases { #expect(modules.shows(.destination(destination))) }
  }

  @Test("should show every module until the first read")
  func shouldShowEveryModuleWhileReading() {
    let modules = MemoirModules()

    #expect(modules.selection == .all)
    #expect(modules.shows(.destination(.today)))
  }
}
