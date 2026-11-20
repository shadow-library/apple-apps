@testable import ShadowSyncCloudKit

/// Records every saved state; once told to, holds the next save until released.
actor HeldStateStore: CloudKitStateStore {
  private(set) var saved: [CloudKitIndexState] = []
  private var holding = false
  private var held: CheckedContinuation<Void, Never>?
  private var arrival: CheckedContinuation<Void, Never>?

  func holdNext() {
    holding = true
  }

  func waitUntilHeld() async {
    guard held == nil else { return }
    await withCheckedContinuation { arrival = $0 }
  }

  func release() {
    held?.resume()
    held = nil
  }

  func load() -> CloudKitStoredIndex {
    saved.last.map(CloudKitStoredIndex.state) ?? .absent
  }

  func save(_ state: CloudKitIndexState) async {
    if holding {
      holding = false
      arrival?.resume()
      arrival = nil
      await withCheckedContinuation { held = $0 }
    }
    saved.append(state)
  }
}
