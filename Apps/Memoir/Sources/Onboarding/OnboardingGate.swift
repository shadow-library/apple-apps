import Foundation
import MemoirCore
import Observation
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// Shows onboarding while the vault is empty and the app as soon as it is not: when onboarding writes, or when sync brings another device's data first.
/// Once the app shows it stays: a vault is never sent back to onboarding.
@MainActor
@Observable
final class OnboardingGate {
  enum State: Equatable {
    case checking
    case needed
    case done
  }

  private(set) var state = State.checking

  /// A read that fails shows the app, whose screens say what went wrong, rather than offering to set up a vault that may have data.
  func run(stores: MemoirStores) async {
    guard state != .done else { return }
    do {
      for try await needed in stores.main.observeReads({ transaction in try OnboardingStanding.isNeeded(in: transaction) }) {
        guard needed else {
          state = .done
          return
        }
        state = .needed
      }
    } catch is CancellationError {
      return
    } catch {
      state = .done
    }
  }
}

struct MemoirOnboardingGate<Content: View>: View {
  let context: MemoirScreenContext
  @ViewBuilder let content: () -> Content
  @State private var gate = OnboardingGate()

  var body: some View {
    Group {
      switch gate.state {
      case .checking: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(ShadowColor.surfaceApp)
      case .needed: OnboardingView(context: context)
      case .done: content()
      }
    }
    .task { await gate.run(stores: context.stores) }
  }
}
