import Foundation
import NovelForgeCore
import Observation

/// The day the owner declared on this device that they are 18 or older. It is kept in this device's defaults and never synced, and no birth date is asked
/// for or kept.
struct AdultConfirmationStore {
  static let key = "com.shadow.apps.novelforge.unrestricted.adult-confirmed-on"

  let defaults: UserDefaults

  func load() -> Date? {
    defaults.object(forKey: Self.key) as? Date
  }

  func save(_ day: Date) {
    defaults.set(day, forKey: Self.key)
  }

  func clear() {
    defaults.removeObject(forKey: Self.key)
  }
}

/// The age gate unrestricted writing needs on this device (shadow-native-apps-plan "When it is offered"). `gate` mirrors it for the engines, and `changed`
/// tells the chats, which turn Unrestricted off on a withdrawal.
@MainActor
@Observable
final class AdultConfirmationModel {
  let gate: AgeGate
  private(set) var confirmedOn: Date?
  @ObservationIgnored var changed: ((_ confirmed: Bool) -> Void)?
  @ObservationIgnored private let store: AdultConfirmationStore

  init(store: AdultConfirmationStore) {
    self.store = store
    let confirmedOn = store.load()
    self.confirmedOn = confirmedOn
    gate = AgeGate(passed: confirmedOn != nil)
  }

  static func live() -> AdultConfirmationModel {
    AdultConfirmationModel(store: AdultConfirmationStore(defaults: .standard))
  }

  var isConfirmed: Bool { confirmedOn != nil }

  func confirm(on day: Date = Date()) {
    store.save(day)
    confirmedOn = day
    gate.update(passed: true)
    changed?(true)
  }

  func withdraw() {
    store.clear()
    confirmedOn = nil
    gate.update(passed: false)
    changed?(false)
  }
}
