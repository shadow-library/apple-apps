import Foundation
import MemoirCore
import ShadowAppShell
import Testing

@testable import Memoir

@MainActor
@Suite("Memoir diagnostics", TestTimeLimit.quick)
struct MemoirDiagnosticsTests {
  private static let versions: [String: DiagnosticsValue] = [
    "rulesetVersion": .count(Ruleset.current.version), "replayVersion": .count(MemoirReconciler.replayVersion),
    "replayCodingVersion": .count(ReplayState.codingVersion),
  ]

  @Test("should report the versions replay runs under and whether this device reminds", arguments: [true, false])
  func shouldReportReplayVersionsAndReminders(reminds: Bool) throws {
    let suite = "MemoirDiagnosticsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let summary = MemoirDiagnostics.summary(isDemo: false, reminders: ReminderDeviceSetting(defaults: defaults, remindsByDefault: reminds))

    #expect(summary == Self.versions.merging(["remindsOnThisDevice": .flag(reminds)]) { $1 })
  }

  @Test("should leave the owner's reminder setting out of a report built in the demo")
  func shouldLeaveTheOwnersReminderSettingOutOfTheDemo() throws {
    let suite = "MemoirDiagnosticsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let summary = MemoirDiagnostics.summary(isDemo: true, reminders: ReminderDeviceSetting(defaults: defaults, remindsByDefault: true))

    #expect(summary == Self.versions)
  }
}
