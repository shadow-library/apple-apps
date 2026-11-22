import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForge

@MainActor
@Suite("Age gate", TestTimeLimit.standard)
struct AgeGateTests {
  private static func defaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "com.shadow.apps.novelforge.tests.age-gate-\(UUID().uuidString)"))
  }

  @Test("should keep only the day the owner confirmed, under the app's own key, until it is withdrawn")
  func shouldPersistTheConfirmationUntilWithdrawn() throws {
    let suite = "com.shadow.apps.novelforge.tests.age-gate-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let day = Date(timeIntervalSince1970: 1_790_000_000)
    let adult = AdultConfirmationModel(store: AdultConfirmationStore(defaults: defaults))
    #expect(!adult.isConfirmed && !adult.gate.isPassed)

    adult.confirm(on: day)

    #expect(adult.confirmedOn == day && adult.gate.isPassed)
    let stored = defaults.persistentDomain(forName: suite) ?? [:]
    #expect(Array(stored.keys) == [AdultConfirmationStore.key])
    #expect(stored[AdultConfirmationStore.key] as? Date == day)
    let relaunched = AdultConfirmationModel(store: AdultConfirmationStore(defaults: defaults))
    #expect(relaunched.confirmedOn == day && relaunched.gate.isPassed)

    relaunched.withdraw()

    #expect(!relaunched.isConfirmed && !relaunched.gate.isPassed)
    #expect(defaults.object(forKey: AdultConfirmationStore.key) == nil)
    #expect(!AdultConfirmationModel(store: AdultConfirmationStore(defaults: defaults)).gate.isPassed)
  }

  @Test("should turn Unrestricted off in every composer of the vault when the confirmation is withdrawn")
  func shouldTurnUnrestrictedOffWhenWithdrawn() async throws {
    let world = try await ChatWorld.make()
    let adult = AdultConfirmationModel(store: AdultConfirmationStore(defaults: try Self.defaults()))
    adult.confirm()
    let runtimes = ChatRuntimes(adult: adult)
    let services = AIServices.novelForge(defaults: try Self.defaults())
    let chats = runtimes.runtime(for: world.store, services: services).model(for: world.context)
    let session = chats.session(try await world.session())
    chats.composer.replyOptions = ChatReplyOptions(thinkDeeper: true, unrestricted: true)
    session.composer.replyOptions = ChatReplyOptions(thinkDeeper: true, unrestricted: true)

    adult.withdraw()

    #expect(chats.composer.replyOptions == ChatReplyOptions(thinkDeeper: true, unrestricted: false))
    #expect(session.composer.replyOptions == ChatReplyOptions(thinkDeeper: true, unrestricted: false))
    #expect(!runtimes.runtime(for: world.store, services: services).engine.unrestrictedAvailable)
  }

  @Test("should offer unrestricted writing only with the build, a model and a covered language, and through the gate until the owner confirms")
  func shouldDecideTheOffer() {
    for available in [false, true] {
      for model in [false, true] {
        for language in [false, true] {
          for adult in [false, true] {
            let offer = UnrestrictedOffer.decide(available: available, modelAssigned: model, languageCovered: language, adultConfirmed: adult)
            let expected: UnrestrictedOffer =
              if !available { .notInThisBuild } else if !model { .needsModel } else if !language { .uncoveredLanguage } else if !adult {
                .needsAgeConfirmation
              } else { .offered }
            #expect(offer == expected)
          }
        }
      }
    }
  }

  @Test("should read the assignment and the confirmation each time it offers")
  func shouldReadTheDeviceEachTime() throws {
    let adult = AdultConfirmationModel(store: AdultConfirmationStore(defaults: try Self.defaults()))
    var assignments = OpenRouterAssignments()
    let access = UnrestrictedAccess(available: true, modelAssigned: { assignments.hasUnrestrictedModel }, adultConfirmed: { adult.isConfirmed })
    #expect(access.offer(languageCovered: true) == .needsModel)
    assignments.unrestricted = "  "
    #expect(access.offer(languageCovered: true) == .needsModel)
    assignments.unrestricted = "or/unrestricted"
    #expect(access.offer(languageCovered: true) == .needsAgeConfirmation)
    adult.confirm()
    #expect(access.offer(languageCovered: true) == .offered)
    adult.withdraw()
    #expect(access.offer(languageCovered: true) == .needsAgeConfirmation)
  }

  @Test("should offer Unrestricted through the gate for a covered English novel with a model, and plainly once the owner confirms")
  func shouldOfferThroughTheGateThenPlainly() async throws {
    let world = try await ChatWorld.make()
    let novel = world.novel
    var changes = NovelChanges()
    changes.writingStyle = .set(Self.english)
    try await world.store.writeDomain { [changes] transaction throws(DomainError) in try Library.edit(novel: novel, changes, in: &transaction) }
    let adult = AdultConfirmationModel(store: AdultConfirmationStore(defaults: try Self.defaults()))
    let access = UnrestrictedAccess(available: true, modelAssigned: { true }, adultConfirmed: { adult.isConfirmed })
    let chats = ChatNovelModel(context: world.context, engine: world.engine, access: access)
    let observing = Task { await chats.observe() }
    defer { observing.cancel() }

    try await ChatWait.until("the novel's language is read") { chats.replyOffer.unrestricted != .hidden }
    #expect(chats.replyOffer.unrestricted == .gated)
    adult.confirm()
    #expect(chats.replyOffer.unrestricted == .open)
    adult.withdraw()
    #expect(chats.replyOffer.unrestricted == .gated)
  }

  @Test("should leave no way to unrestricted writing while this build lacks it", .enabled(if: !UnrestrictedWriting.isAvailable))
  func shouldOfferNothingWithoutTheBuildFlag() async throws {
    let adult = AdultConfirmationModel(store: AdultConfirmationStore(defaults: try Self.defaults()))
    adult.confirm()
    let access = UnrestrictedAccess(modelAssigned: { true }, adultConfirmed: { adult.isConfirmed })
    #expect(access.offer(languageCovered: true) == .notInThisBuild)
    #expect(ChatReplyOffer(novel: NovelRecord(id: UUID(), name: "Ashfall"), unrestricted: access.offer(languageCovered: true)).unrestricted == .hidden)

    let world = try await ChatWorld.make()
    let runtime = ChatRuntimes(adult: adult).runtime(for: world.store, services: AIServices.novelForge(defaults: try Self.defaults()))
    #expect(!runtime.engine.unrestrictedAvailable)
    let chats = runtime.model(for: world.context)
    let observing = Task { await chats.observe() }
    defer { observing.cancel() }
    try await ChatWait.until("the chats load") { chats.state.value != nil }
    #expect(chats.replyOffer.unrestricted == .hidden)
  }

  private nonisolated static let english = "Close third person in the past tense, with short plain sentences, salt in the air and the sea always somewhere close by."
}
