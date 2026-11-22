import Foundation
import MemoirCore
import ShadowAppShell
import Testing

@testable import Memoir

@MainActor
@Suite("Memoir diagnostics", TestTimeLimit.quick)
struct MemoirDiagnosticsTests {
  @Test("should report the versions replay runs under and whether this device reminds", arguments: [true, false])
  func shouldReportReplayVersionsAndReminders(reminds: Bool) throws {
    let suite = "MemoirDiagnosticsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let summary = MemoirDiagnostics.summary(reminders: ReminderDeviceSetting(defaults: defaults, remindsByDefault: reminds))

    #expect(
      summary == [
        "rulesetVersion": .count(Ruleset.current.version), "replayVersion": .count(MemoirReconciler.replayVersion),
        "replayCodingVersion": .count(ReplayState.codingVersion), "remindsOnThisDevice": .flag(reminds),
      ])
  }
}
