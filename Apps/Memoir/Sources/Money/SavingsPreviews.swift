#if DEBUG
  import Foundation
  import MemoirCore
  import ShadowCore
  import ShadowDesignSystem
  import ShadowStore
  import SwiftUI

  /// In-memory stores holding the demo's sample week: Home with five closed months, three of them depositing, and the "New bike" goal.
  private struct SavingsPreviewHost<Content: View>: View {
    @ViewBuilder let content: (MemoirScreenContext, SavingsSnapshot?) -> Content
    @State private var loaded: (context: MemoirScreenContext, snapshot: SavingsSnapshot?)?

    var body: some View {
      NavigationStack {
        if let loaded {
          content(loaded.context, loaded.snapshot).navigationDestination(for: MemoirRoute.self) { MemoirRouteView(route: $0, context: loaded.context) }
        } else {
          ProgressView()
        }
      }
      .task {
        guard loaded == nil, let context = try? MemoirScreenContext.inMemory(), let euro = CurrencyCode("EUR") else { return }
        try? await MemoirDemo.seed(context.stores, now: context.clock.now(), zone: context.clock.deviceZone(), currency: euro)
        let clock = context.clock
        let snapshot = try? await context.stores.main.read { transaction in try SavingsSnapshot.load(in: transaction, clock: clock) }
        loaded = (context, snapshot ?? nil)
      }
    }
  }

  #Preview("Money with savings") {
    SavingsPreviewHost { context, _ in MoneyView(context: context) }.shadowTheme()
  }

  #Preview("Savings card") {
    SavingsPreviewHost { _, snapshot in
      ScrollView {
        if let snapshot {
          VStack(spacing: Spacing.space4) {
            GoalsCard(snapshot: snapshot)
            SavingsCard(snapshot: snapshot)
          }
          .padding(Spacing.space4)
        }
      }
    }
    .shadowTheme()
  }

  #Preview("Goals") {
    SavingsPreviewHost { context, _ in GoalsView(context: context) }.shadowTheme()
  }

  #Preview("Goal") {
    SavingsPreviewHost { context, snapshot in
      if let goal = snapshot?.active.first { GoalView(id: goal.id, context: context) }
    }
    .shadowTheme()
  }

  #Preview("New goal") {
    SavingsPreviewHost { context, _ in GoalFormScreen(editing: nil, context: context) }.shadowTheme()
  }

  #Preview("Expense from savings") {
    SavingsPreviewHost { context, _ in ExpenseFormScreen(editing: nil, context: context) }.shadowTheme()
  }
#endif
