import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

/// An in-memory vault at noon of `TestClock.day0` with the device in UTC, optionally with a zone in force and a settings record, as onboarding leaves it.
@MainActor
final class SettingsWorld {
  nonisolated static let english = AmountFormat(decimalSeparator: ".", groupingSeparator: ",")
  nonisolated static let german = AmountFormat(decimalSeparator: ",", groupingSeparator: ".")

  let clock: TestClock
  let opened: MemoirOpenedVault
  let context: MemoirScreenContext
  private var tasks: [Task<Void, Never>] = []

  init(zone: String? = "UTC", currency: String? = "EUR", clock: MemoirClock? = nil) async throws {
    let testClock = TestClock(day: 0, minute: 720)
    self.clock = testClock
    opened = try await MemoirVaultOpener.open(.inMemory, appVersion: "1", clock: clock ?? testClock.memoir(deviceZone: TestClock.utc))
    context = MemoirScreenContext(opened)
    if let zone { try await context.writer.issue(try TestQuests.zone(zone)) }
    if let currency { try await createSettings(currency) }
  }

  func createSettings(_ currency: String) async throws {
    let code = try #require(CurrencyCode(currency))
    try await context.writer.write { _, transaction in
      _ = try AccountSettingsRecord(defaultCurrency: code, enabledCurrencies: [code]).create(in: &transaction)
    }
  }

  func settingsModel(format: AmountFormat = SettingsWorld.english, scheduleDelay: Duration = .zero) async throws -> SettingsModel {
    let model = SettingsModel(context: context, format: format, scheduleDelay: scheduleDelay)
    tasks.append(Task { await model.run() })
    try await until("the settings") { model.snapshot.state.value != nil && model.today != nil }
    return model
  }

  func gate() async throws -> OnboardingGate {
    let gate = OnboardingGate()
    let stores = context.stores
    tasks.append(Task { await gate.run(stores: stores) })
    try await until("the gate's first read") { gate.state != .checking }
    return gate
  }

  func stop() {
    for task in tasks { task.cancel() }
  }

  func record() async throws -> AccountSettingsRecord? {
    try await context.stores.main.read { transaction in try AccountSettingsRecord.read(key: .accountSettings, in: transaction).entry?.record }
  }

  func bodies() async throws -> [MemoirCommandBody] {
    let entries = try await context.stores.main.read { transaction in try MemoirCommand.listing(in: transaction).entries }
    return try entries.sorted { $0.clock < $1.clock }.map { try MemoirCommandBody($0.record) }
  }

  func commands() async throws -> [MemoirCommand] {
    let entries = try await context.stores.main.read { transaction in try MemoirCommand.listing(in: transaction).entries }
    return entries.sorted { $0.clock < $1.clock }.map(\.record)
  }
}
