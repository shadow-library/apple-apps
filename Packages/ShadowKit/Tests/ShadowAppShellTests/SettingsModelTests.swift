import Foundation
import ShadowAI
import ShadowKeychain
import Testing

@testable import ShadowAppShell

@MainActor
@Suite("AISettingsModel", TestTimeLimit.standard)
struct SettingsModelTests {
  private func entry(_ model: AISettingsModel, _ provider: ModelProviderKind, _ text: String) {
    model.keyDrafts[provider] = text
  }

  @Test("should save a key the provider accepts, clear the draft and mask it afterwards")
  func shouldSaveAKeyTheProviderAcceptsAndClearTheDraft() async throws {
    let world = try SettingsFixtures.world { provider, credential in
      #expect(provider == .anthropic)
      #expect(credential.secret == SettingsFixtures.secret)
      return .valid(label: nil)
    }
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)
    entry(model, .anthropic, "  \(SettingsFixtures.secret)\n")

    await model.submitKey(for: .anthropic)

    #expect(model.storedKeys == [.anthropic])
    #expect(model.keyDrafts[.anthropic] == nil)
    #expect(model.entry(.anthropic) == .idle)
    #expect(try await world.services.keys.credential(for: .anthropic)?.secret == SettingsFixtures.secret)
  }

  @Test("should not save a key the provider rejects")
  func shouldNotSaveAKeyTheProviderRejects() async throws {
    let world = try SettingsFixtures.world { _, _ in .invalid }
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)
    entry(model, .anthropic, SettingsFixtures.secret)

    await model.submitKey(for: .anthropic)

    guard case .rejected(let error) = model.entry(.anthropic) else {
      Issue.record("The key was not rejected.")
      return
    }
    #expect(!error.headline.contains(SettingsFixtures.secret))
    #expect(world.secure.accounts.isEmpty)
    #expect(model.storedKeys.isEmpty)
  }

  @Test("should hold an unverifiable key until the author saves it anyway, and drop that offer when the draft changes")
  func shouldHoldAnUnverifiableKeyUntilSavedAnyway() async throws {
    let world = try SettingsFixtures.world { _, _ in .unverified(.transport(.notConnectedToInternet)) }
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)
    entry(model, .openRouter, SettingsFixtures.secret)

    await model.submitKey(for: .openRouter)
    guard case .unverified(let error) = model.entry(.openRouter) else {
      Issue.record("The key was not held as unverified.")
      return
    }
    #expect(error.detail == "model.transport")
    #expect(world.secure.accounts.isEmpty)

    entry(model, .openRouter, "another-key")
    model.keyDraftChanged(.openRouter)
    #expect(model.entry(.openRouter) == .idle)
    await model.saveUnverified(for: .openRouter)
    #expect(world.secure.accounts.isEmpty)

    await model.submitKey(for: .openRouter)
    await model.saveUnverified(for: .openRouter)
    #expect(world.secure.accounts == ["ai.openrouter.api-key"])
  }

  @Test("should show a validation call that throws as unverified and a cancelled one as idle")
  func shouldShowAThrowingCheckAsUnverifiedAndACancelledOneAsIdle() async throws {
    let failing = try SettingsFixtures.world(validation: SettingsFixtures.failing(.server(status: 500)))
    defer { failing.tearDown() }
    let model = AISettingsModel(services: failing.services, store: failing.store)
    entry(model, .anthropic, SettingsFixtures.secret)
    await model.submitKey(for: .anthropic)
    guard case .unverified = model.entry(.anthropic) else {
      Issue.record("A server failure was not shown as unverified.")
      return
    }

    let cancelled = try SettingsFixtures.world(validation: SettingsFixtures.failing(.cancelled))
    defer { cancelled.tearDown() }
    let other = AISettingsModel(services: cancelled.services, store: cancelled.store)
    entry(other, .anthropic, SettingsFixtures.secret)
    await other.submitKey(for: .anthropic)
    #expect(other.entry(.anthropic) == .idle)
  }

  @Test("should report a keychain that refuses the write and store nothing")
  func shouldReportAKeychainThatRefusesTheWrite() async throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    world.secure.failsWrites = true
    let model = AISettingsModel(services: world.services, store: world.store)
    entry(model, .anthropic, SettingsFixtures.secret)

    await model.submitKey(for: .anthropic)

    guard case .failed(let error) = model.entry(.anthropic) else {
      Issue.record("The write failure was not reported.")
      return
    }
    #expect(error.detail == "secure_store.unexpected_status (-34018)")
    #expect(model.storedKeys.isEmpty)
  }

  @Test("should refuse an empty draft and ignore a second submit while checking")
  func shouldRefuseAnEmptyOrMalformedDraft() async throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)
    entry(model, .anthropic, "   ")
    #expect(!model.canSubmitKey(.anthropic))
    entry(model, .anthropic, "bad\u{7}key")
    await model.submitKey(for: .anthropic)
    guard case .rejected = model.entry(.anthropic) else {
      Issue.record("A key with control characters was accepted.")
      return
    }
    #expect(world.secure.accounts.isEmpty)
  }

  @Test("should remove a key and the cached OpenRouter list, and tolerate removing it twice")
  func shouldRemoveAKeyAndTheCachedModelListTwiceWithoutError() async throws {
    let world = try SettingsFixtures.world(listing: { [RemoteModel(id: "vendor/model")] })
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)
    entry(model, .openRouter, SettingsFixtures.secret)
    await model.submitKey(for: .openRouter)
    #expect(model.listedModels.map(\.id) == ["vendor/model"])

    await model.removeKey(.openRouter)
    await model.removeKey(.openRouter)

    #expect(model.storedKeys.isEmpty)
    #expect(world.secure.accounts.isEmpty)
    #expect(model.listedModels.isEmpty)
    #expect(model.failure == nil)
  }

  @Test("should save one model per pace, trimming and dropping empty ones, and reject identifiers with spaces")
  func shouldSaveOneModelPerPaceAndRejectIdentifiersWithSpaces() throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)
    model.modelDrafts[.swift] = "  vendor/fast "
    model.modelDrafts[.steady] = ""
    model.modelDrafts[.meticulous] = "two words"
    #expect(model.modelIssue(.meticulous) == .invalid)
    #expect(!model.canSaveModels)

    model.modelDrafts[.meticulous] = "vendor/deep"
    #expect(model.canSaveModels)
    model.saveModels()

    #expect(world.services.settings.assignments.models == [.swift: "vendor/fast", .meticulous: "vendor/deep"])
    #expect(model.modelDrafts[.swift] == "vendor/fast")
    #expect(!model.hasModelChanges)
  }

  @Test("should save spend caps, clear a cap when emptied, and reject a daily cap above the monthly one")
  func shouldSaveSpendCapsAndRejectADailyCapAboveTheMonthlyOne() throws {
    let world = try SettingsFixtures.world()
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)
    model.dailyText = "10"
    model.monthlyText = "5"
    #expect(model.dailyIssue == .dailyAboveMonthly)
    #expect(!model.canSaveCaps)

    model.dailyText = "2"
    model.saveCaps()
    #expect(world.services.settings.limits == SpendLimits(daily: Cost(nanoUSD: 2 * Cost.nanoUSDPerUSD), monthly: Cost(nanoUSD: 5 * Cost.nanoUSDPerUSD)))

    model.dailyText = ""
    model.monthlyText = ""
    model.saveCaps()
    #expect(world.services.settings.limits == SpendLimits())
  }

  @Test("should list OpenRouter models after the key is saved and report a list failure without blocking free text")
  func shouldListModelsAfterSavingAKeyAndAllowFreeTextOnFailure() async throws {
    let world = try SettingsFixtures.world(listing: SettingsFixtures.failingListing(.authentication))
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)
    entry(model, .openRouter, SettingsFixtures.secret)

    await model.submitKey(for: .openRouter)

    #expect(model.storedKeys == [.openRouter])
    #expect(model.modelsFailure?.detail == "model.authentication")
    model.modelDrafts[.swift] = "vendor/typed-by-hand"
    #expect(model.canSaveModels)
  }

  @Test("should not persist a key whose check finishes after the key was removed")
  func shouldNotPersistACheckThatFinishesAfterTheKeyWasRemoved() async throws {
    let slow: CredentialValidation = { (_, _) async throws(ModelError) -> CredentialStatus in
      try? await Task.sleep(for: .milliseconds(200))
      return .valid(label: nil)
    }
    let world = try SettingsFixtures.world(validation: slow)
    defer { world.tearDown() }
    let model = AISettingsModel(services: world.services, store: world.store)
    entry(model, .anthropic, SettingsFixtures.secret)

    let submitting = Task { await model.submitKey(for: .anthropic) }
    while model.entry(.anthropic) != .checking { await Task.yield() }
    await model.removeKey(.anthropic)
    await submitting.value

    #expect(world.secure.accounts.isEmpty)
    #expect(model.storedKeys.isEmpty)
    #expect(model.entry(.anthropic) == .idle)
  }
}
