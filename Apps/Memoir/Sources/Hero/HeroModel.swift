import Foundation
import MemoirCore
import Observation
import ShadowAppShell

enum HeroAction: Hashable, Sendable {
  case display(TitleID)
  case clearTitle
  case unlock(CosmeticID)
  case equip(CosmeticID)
}

struct WithdrawnPurchase: Hashable {
  let cosmetic: CosmeticID
  let refusal: ReplayRefusal
  var commands: [UUID]
}

struct HeroFailure: Equatable {
  let action: HeroAction
  let error: PresentedError
}

/// A cosmetic as the Cosmetics tab offers it: the deck's state, with the Bronze badge shown as the starter crest until it is owned
/// (`synced-hero-provider.ts:139-153`), so it is never offered for coins.
enum CosmeticOffer: Equatable {
  case equipped
  case owned
  case affordable(price: Int)
  case short(by: Int)
  case achievementOnly
  case starter(equipped: Bool)

  static let starterCrest = CosmeticID.badgeBronze

  init(_ standing: CosmeticStanding, in deck: HeroDeck) {
    if standing.id == Self.starterCrest && !standing.state.isOwned {
      self = .starter(equipped: !deck.cosmetics.contains { $0.kind == standing.kind && $0.state.isEquipped })
      return
    }
    switch standing.state {
    case .equipped: self = .equipped
    case .owned: self = .owned
    case .affordable: self = standing.priceCoins.map { .affordable(price: $0) } ?? .achievementOnly
    case .short(let shortfall): self = .short(by: shortfall)
    case .achievementOnly: self = .achievementOnly
    }
  }
}

extension CosmeticState {
  var isEquipped: Bool {
    guard case .equipped = self else { return false }
    return true
  }

  var isOwned: Bool {
    switch self {
    case .equipped, .owned: true
    case .affordable, .short, .achievementOnly: false
    }
  }
}

/// The Hero screen's deck and its writes. A change the deck already shows as impossible is refused here with the reference's code, as memoir-web
/// refuses it before sending (`synced-hero-provider.ts:105-133`); one that replay later withdraws comes back as a notice on the deck.
@MainActor
@Observable
final class HeroModel {
  let deck = ReadObserver<HeroDeck>()
  private(set) var today: LocalDate?
  private(set) var pending: HeroAction?
  var failure: HeroFailure?
  private(set) var acknowledged: Set<UUID>

  private let context: MemoirScreenContext
  private let acknowledgements: WithdrawalAcknowledgements

  init(context: MemoirScreenContext, acknowledgements: WithdrawalAcknowledgements = WithdrawalAcknowledgements()) {
    self.context = context
    self.acknowledgements = acknowledgements
    acknowledged = acknowledgements.commands
  }

  func run() async {
    let main = context.stores.main
    async let today: Void = followToday()
    await deck.run { main.observe(HeroDeck.self, HeroDeckQuery()) }
    await today
  }

  /// Purchases replay withdrew for want of coins, one per cosmetic with its latest refusal, leaving out those dismissed and any bought since.
  var withdrawnPurchases: [WithdrawnPurchase] {
    guard let deck = deck.state.value else { return [] }
    let owned = Set(deck.cosmetics.filter(\.state.isOwned).map(\.id))
    var withdrawn: [WithdrawnPurchase] = []
    for notice in deck.notices.reversed() {
      guard case .purchaseWithdrawn(let command, let cosmetic, let balance, let price) = notice, !owned.contains(cosmetic), !acknowledged.contains(command) else {
        continue
      }
      if let index = withdrawn.firstIndex(where: { $0.cosmetic == cosmetic }) {
        withdrawn[index].commands.append(command)
      } else {
        withdrawn.append(WithdrawnPurchase(cosmetic: cosmetic, refusal: .notEnoughCoins(balance: balance, required: price), commands: [command]))
      }
    }
    return withdrawn
  }

  func acknowledge(_ withdrawn: WithdrawnPurchase) {
    acknowledgements.acknowledge(withdrawn.commands)
    acknowledged.formUnion(withdrawn.commands)
  }

  func display(_ title: TitleID) async {
    guard let standing = deck.state.value?.titles.first(where: { $0.id == title }), !standing.isDisplayed else { return }
    guard standing.earnedOn != nil else { return refuse(.display(title), ReplayRefusal.titleNotEarned(title)) }
    await perform(.display(title), .titleDisplay(TitleDisplay(title: title)))
  }

  func clearTitle() async {
    guard deck.state.value?.titles.contains(where: \.isDisplayed) == true else { return }
    await perform(.clearTitle, .titleDisplay(TitleDisplay(title: nil)))
  }

  func unlock(_ cosmetic: CosmeticID) async {
    guard let deck = deck.state.value, let standing = deck.cosmetics.first(where: { $0.id == cosmetic }), !standing.state.isOwned else { return }
    guard let price = standing.priceCoins else { return refuse(.unlock(cosmetic), CommandRefusal.cosmeticNotForSale(cosmetic)) }
    guard deck.coins >= price else { return refuse(.unlock(cosmetic), ReplayRefusal.notEnoughCoins(balance: deck.coins, required: price)) }
    await perform(.unlock(cosmetic), .cosmeticPurchase(cosmetic))
  }

  func equip(_ cosmetic: CosmeticID) async {
    guard let standing = deck.state.value?.cosmetics.first(where: { $0.id == cosmetic }), !standing.state.isEquipped else { return }
    guard standing.state.isOwned else { return refuse(.equip(cosmetic), ReplayRefusal.cosmeticNotOwned(cosmetic)) }
    await perform(.equip(cosmetic), .cosmeticEquip(cosmetic))
  }

  private func perform(_ action: HeroAction, _ body: MemoirCommandBody) async {
    guard pending == nil else { return }
    pending = action
    defer { pending = nil }
    do {
      try await context.writer.issue(body)
    } catch {
      refuse(action, error)
    }
  }

  private func refuse(_ action: HeroAction, _ error: any Error) {
    failure = WritingErrors.presented(error).map { HeroFailure(action: action, error: $0) }
  }

  private func followToday() async {
    do {
      for try await today in context.observeToday() { self.today = today.date }
    } catch {
      today = nil
    }
  }
}
