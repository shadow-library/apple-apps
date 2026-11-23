import MemoirCore
import ShadowAppShell

extension DiagnosticsSources {
  static func memoir(_ opened: MemoirOpenedVault?, sync: SyncRuntimes, ai: AIServices) -> DiagnosticsSources {
    let stores = opened.map { ["activity": $0.stores.activity, "restricted": $0.stores.restricted] } ?? [:]
    let isDemo = ai.isDemo
    return DiagnosticsSources(sync: sync, ai: ai, primary: opened?.stores.main, stores: stores) { await MemoirDiagnostics.summary(isDemo: isDemo) }
  }
}

/// Memoir's part of a diagnostics report: the versions replay runs under and, outside the demo, whether this device reminds.
enum MemoirDiagnostics {
  static func summary(isDemo: Bool, reminders: ReminderDeviceSetting = ReminderDeviceSetting()) -> [String: DiagnosticsValue] {
    var summary: [String: DiagnosticsValue] = [
      "rulesetVersion": .count(Ruleset.current.version),
      "replayVersion": .count(MemoirReconciler.replayVersion),
      "replayCodingVersion": .count(ReplayState.codingVersion),
    ]
    if !isDemo { summary["remindsOnThisDevice"] = .flag(reminders.isOn) }
    return summary
  }
}
