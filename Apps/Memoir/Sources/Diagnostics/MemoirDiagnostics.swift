import MemoirCore
import ShadowAppShell

extension DiagnosticsSources {
  static func memoir(_ opened: MemoirOpenedVault?, sync: SyncRuntimes, ai: AIServices) -> DiagnosticsSources {
    let stores = opened.map { ["activity": $0.stores.activity, "restricted": $0.stores.restricted] } ?? [:]
    return DiagnosticsSources(sync: sync, ai: ai, primary: opened?.stores.main, stores: stores) { await MemoirDiagnostics.summary() }
  }
}

/// Memoir's part of a diagnostics report: the versions replay runs under and whether this device reminds.
enum MemoirDiagnostics {
  static func summary(reminders: ReminderDeviceSetting = ReminderDeviceSetting()) -> [String: DiagnosticsValue] {
    [
      "rulesetVersion": .count(Ruleset.current.version),
      "replayVersion": .count(MemoirReconciler.replayVersion),
      "replayCodingVersion": .count(ReplayState.codingVersion),
      "remindsOnThisDevice": .flag(reminders.isOn),
    ]
  }
}
