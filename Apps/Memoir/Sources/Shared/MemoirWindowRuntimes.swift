import ShadowAppShell
import SwiftUI

/// One vault and what serves its screens: its AI services, sync, insights, day turns and, for the owner's vault only, exchange rates and budget closes.
@MainActor
struct MemoirRuntimeSet {
  let vault: MemoirVaultModel
  let ai: AIServices
  let sync: SyncRuntimes
  let insights: MemoirInsights
  let dayTurns: MemoirDayTurns
  var rates: MemoirRates?
  var closer: BudgetPeriodCloser?

  func phaseChanged(_ phase: ScenePhase) async {
    if phase == .active { dayTurns.restart() }
    rates?.phaseChanged(isActive: phase == .active)
    closer?.phaseChanged(isActive: phase == .active)
    async let syncing: Void = sync.phaseChanged(phase)
    async let asking: Void = insights.phaseChanged(isActive: phase == .active)
    _ = await (syncing, asking)
  }
}

/// What the window runs on: the demo's set while the demo is on, the owner's otherwise. The owner's set keeps its vault and hears every scene phase while
/// the demo runs, so its sync, insights, day turns and Health imports still follow the app to the background and back.
@MainActor
final class MemoirWindowRuntimes {
  let owner: MemoirRuntimeSet
  let demo: MemoirDemoSession
  private let ownerVaultChanged: @MainActor () async -> Void
  private let ownerForegrounded: @MainActor () -> Void

  /// `ownerVaultChanged` follows a newly opened owner's vault (day turns, reminders, sync, insights); `ownerForegrounded` runs its Health imports.
  init(
    owner: MemoirRuntimeSet, demo: MemoirDemoSession, ownerVaultChanged: @escaping @MainActor () async -> Void,
    ownerForegrounded: @escaping @MainActor () -> Void
  ) {
    self.owner = owner
    self.demo = demo
    self.ownerVaultChanged = ownerVaultChanged
    self.ownerForegrounded = ownerForegrounded
  }

  var active: MemoirRuntimeSet { demo.active?.runtimes ?? owner }

  var isDemo: Bool { demo.active != nil }

  /// The window's vault opened or changed: the demo follows its own, and only the owner's vault reaches the owner's reminders, sync and Health.
  func activeVaultChanged() async {
    if let running = demo.active { return await running.vaultChanged() }
    await ownerVaultChanged()
    ownerForegrounded()
  }

  func phaseChanged(_ phase: ScenePhase) async {
    if phase == .active { ownerForegrounded() }
    let sets = [owner] + (demo.active.map { [$0.runtimes] } ?? [])
    await withDiscardingTaskGroup { group in
      for set in sets { group.addTask { await set.phaseChanged(phase) } }
    }
  }
}
