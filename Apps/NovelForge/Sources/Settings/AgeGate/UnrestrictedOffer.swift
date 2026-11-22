import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell

/// Whether unrestricted writing is offered for a novel on this device (shadow-native-apps-plan "When it is offered"): once the build has it, a model is
/// assigned to it, the novel's language is one the hard line covers and the owner passed the age gate. Before the gate, it is offered through the gate.
enum UnrestrictedOffer: Equatable {
  case notInThisBuild
  case needsModel
  case uncoveredLanguage
  case needsAgeConfirmation
  case offered

  static func decide(available: Bool, modelAssigned: Bool, languageCovered: Bool, adultConfirmed: Bool) -> UnrestrictedOffer {
    guard available else { return .notInThisBuild }
    guard modelAssigned else { return .needsModel }
    guard languageCovered else { return .uncoveredLanguage }
    return adultConfirmed ? .offered : .needsAgeConfirmation
  }
}

/// What this device contributes to the offer beyond the novel: whether a model is assigned to unrestricted writing, and whether the owner confirmed their age.
/// `available` is the build's flag, which only tests replace: the engines decide on their own `AgeGate` whatever the offer shows.
@MainActor
struct UnrestrictedAccess {
  static let none = UnrestrictedAccess(modelAssigned: { false }, adultConfirmed: { false })

  let available: Bool
  let modelAssigned: () -> Bool
  let adultConfirmed: () -> Bool

  init(available: Bool = UnrestrictedWriting.isAvailable, modelAssigned: @escaping () -> Bool, adultConfirmed: @escaping () -> Bool) {
    self.available = available
    self.modelAssigned = modelAssigned
    self.adultConfirmed = adultConfirmed
  }

  /// The demo offers none: its services refuse unrestricted calls.
  static func live(services: AIServices, adult: AdultConfirmationModel) -> UnrestrictedAccess {
    UnrestrictedAccess(
      available: UnrestrictedWriting.isAvailable && !services.isDemo, modelAssigned: { services.settings.assignments.hasUnrestrictedModel },
      adultConfirmed: { adult.isConfirmed })
  }

  func offer(languageCovered: Bool) -> UnrestrictedOffer {
    .decide(available: available, modelAssigned: modelAssigned(), languageCovered: languageCovered, adultConfirmed: adultConfirmed())
  }
}

extension OpenRouterAssignments {
  /// As `TaskRouter` reads the assignment: a blank one routes nowhere.
  var hasUnrestrictedModel: Bool { !(unrestricted?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }
}
