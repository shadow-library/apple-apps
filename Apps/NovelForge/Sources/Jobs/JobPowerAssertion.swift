import Foundation

/// Keeps the Mac from idle sleep and App Nap while any job runs here (orchestrator decision 9), released when the last one ends.
@MainActor
final class JobPowerAssertion {
  struct Activity {
    let begin: @MainActor () -> (any NSObjectProtocol)?
    let end: @MainActor (any NSObjectProtocol) -> Void

    static let system = Activity(
      begin: {
        #if os(macOS)
          ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Novel Forge is running a chapter job")
        #else
          nil
        #endif
      },
      end: { ProcessInfo.processInfo.endActivity($0) })
  }

  private let activity: Activity
  private var holders = 0
  private var token: (any NSObjectProtocol)?

  init(activity: Activity = .system) {
    self.activity = activity
  }

  var isHeld: Bool { holders > 0 }

  func begin() {
    holders += 1
    guard holders == 1 else { return }
    token = activity.begin()
  }

  /// Ends the activity whatever still holds it, as the vault closes.
  func release() {
    holders = 0
    guard let token else { return }
    activity.end(token)
    self.token = nil
  }

  func end() {
    guard holders > 0 else { return }
    holders -= 1
    guard holders == 0, let token else { return }
    activity.end(token)
    self.token = nil
  }
}
