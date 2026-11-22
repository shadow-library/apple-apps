import MemoirCore
import ShadowDesignSystem
import SwiftUI

/// Cosmetics change nothing about how the game plays; a purchase asks first, an equip does not (`cosmetics-panel.tsx`).
struct HeroCosmeticsSection: View {
  let deck: HeroDeck
  let model: HeroModel
  @State private var confirming: CosmeticID?

  var body: some View {
    let offers = deck.cosmetics.map { (standing: $0, offer: CosmeticOffer($0, in: deck)) }
    VStack(alignment: .leading, spacing: Spacing.space4) {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        Text(verbatim: HeroCopy.coins(deck.coins)).shadowFont(.title3).monospacedDigit().foregroundStyle(ShadowColor.textPrimary)
        Text("Coins come from kept quests and crowns. They cannot be bought, and nothing here changes how the game plays.", tableName: "Hero")
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
        if offers.contains(where: { if case .short = $0.offer { true } else { false } }) {
          Text("Cosmetics you can’t yet afford wait here until your balance reaches them.", tableName: "Hero")
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
      }
      ForEach(model.withdrawnPurchases, id: \.cosmetic) { withdrawn in
        ShadowCallout(
          Text("Couldn’t unlock ‘\(HeroCatalogue.name(of: withdrawn.cosmetic))’ — undone", tableName: "Hero"),
          message: WritingErrors.headline(for: withdrawn.refusal).map { Text(verbatim: $0) }, intent: .warning,
          dismiss: ShadowCalloutDismiss(Text("Dismiss", tableName: "Hero")) { model.acknowledge(withdrawn) })
      }
      ShadowAdaptiveColumns {
        ForEach(offers, id: \.standing.id) { item in card(item.standing, offer: item.offer) }
      }
    }
    .confirmationDialog(
      confirmationTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible, presenting: confirming
    ) { cosmetic in
      Button {
        Task { await model.unlock(cosmetic) }
      } label: {
        Text("Unlock", tableName: "Hero")
      }
      Button(role: .cancel) {
      } label: {
        Text("Cancel", tableName: "Hero")
      }
    } message: { cosmetic in
      Text("Unlock \(HeroCatalogue.name(of: cosmetic)) for \(HeroCopy.coins(cosmetic.priceCoins ?? 0))? You have \(deck.coins).", tableName: "Hero")
    }
  }

  private var confirmationTitle: Text {
    guard let confirming else { return Text(verbatim: "") }
    return Text("Unlock \(HeroCatalogue.name(of: confirming))", tableName: "Hero")
  }

  private func card(_ standing: CosmeticStanding, offer: CosmeticOffer) -> some View {
    let owned = offer == .equipped || offer == .owned || offer == .starter(equipped: true)
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        HStack(spacing: Spacing.space2) {
          Image(systemName: HeroCatalogue.symbol(of: standing.id))
            .foregroundStyle(owned ? ShadowColor.accentText : ShadowColor.textTertiary)
            .accessibilityHidden(true)
          Text(verbatim: HeroCatalogue.name(of: standing.id)).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          if offer == .equipped || offer == .starter(equipped: true) { ShadowBadge(Text("Equipped", tableName: "Hero"), intent: .info) }
        }
        Text(verbatim: HeroCatalogue.note(of: standing.id)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
        action(standing.id, offer: offer)
      }
    }
  }

  @ViewBuilder
  private func action(_ cosmetic: CosmeticID, offer: CosmeticOffer) -> some View {
    switch offer {
    case .starter(equipped: false):
      Text("Starter crest", tableName: "Hero").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
    case .equipped, .starter(equipped: true):
      Button {
      } label: {
        Text("Equipped", tableName: "Hero")
      }
      .buttonStyle(.shadowPlain)
      .disabled(true)
    case .owned:
      Button {
        Task { await model.equip(cosmetic) }
      } label: {
        Text("Equip", tableName: "Hero")
      }
      .buttonStyle(.shadowBordered)
      .disabled(model.pending != nil)
    case .affordable(let price):
      Button {
        confirming = cosmetic
      } label: {
        Text("Unlock for \(HeroCopy.coins(price))", tableName: "Hero")
      }
      .buttonStyle(.shadowBordered)
      .disabled(model.pending != nil)
    case .short(let shortfall):
      Button {
      } label: {
        Text("\(shortfall) more coins", tableName: "Hero")
      }
      .buttonStyle(.shadowBordered)
      .disabled(true)
    case .achievementOnly:
      Button {
      } label: {
        Text("Comes with an achievement", tableName: "Hero")
      }
      .buttonStyle(.shadowBordered)
      .disabled(true)
    }
  }
}
