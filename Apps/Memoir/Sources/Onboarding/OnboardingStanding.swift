import Foundation
import MemoirCore
import ShadowStore

/// Whether the vault still needs setting up. The reference keeps `onboarding_completed_at` on the account and sets it with the home currency, zone and
/// day (`account.service.ts:159-176`); here that is the settings record itself, which syncs, so a second device skips onboarding once the first device's
/// data reaches it. A vault holding any command (written before onboarding existed, or merged without its settings yet) has data and skips it too.
nonisolated enum OnboardingStanding {
  static func isNeeded<Source: RecordSource & ~Copyable>(in source: borrowing Source) throws(StoreError) -> Bool {
    guard case .absent = try AccountSettingsRecord.read(key: .accountSettings, in: source) else { return false }
    let commands = try MemoirCommand.listing(in: source)
    return commands.entries.isEmpty && commands.unreadable == 0
  }
}
