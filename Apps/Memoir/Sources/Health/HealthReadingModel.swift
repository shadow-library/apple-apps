import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

/// Which built-in metrics this device reads from Apple Health, and which device reads for the vault. The first device to turn a metric on becomes the
/// reader; another one asks the owner before it takes over, and the device that lost the designation forgets the metrics it read, so taking the role
/// back starts from the metric turned on then. Turning the last metric off here gives the designation up and forgets what this device had indexed; the
/// imported days stay.
@MainActor
@Observable
final class HealthReadingModel {
  struct Takeover: Equatable {
    let metric: BuiltinMetric
    let current: HealthReaderDesignation
  }

  let environment: HealthEnvironment
  let stores: MemoirStores
  let clock: MemoirClock
  let designation = ReadObserver<HealthReaderDesignation?>()
  private(set) var reading: Set<BuiltinMetric>
  private(set) var busy: BuiltinMetric?
  private(set) var isImporting = false
  private(set) var outcome: HealthImportOutcome?
  private(set) var failure: PresentedError?
  var takeover: Takeover?

  init(environment: HealthEnvironment, stores: MemoirStores, clock: MemoirClock) {
    self.environment = environment
    self.stores = stores
    self.clock = clock
    reading = environment.preferences.metrics
  }

  convenience init(context: MemoirScreenContext) {
    self.init(environment: .live(), stores: context.stores, clock: context.clock)
  }

  var availability: HealthAvailability { environment.availability }

  /// The designation as last read: `.loading` until the main store answers.
  var reader: HealthReaderDesignation? { designation.state.value ?? nil }

  var isThisDeviceReader: Bool { reader != nil && reader?.device == environment.device?.id }

  /// The device that reads Health for the vault when it is not this one.
  var otherReader: HealthReaderDesignation? { isThisDeviceReader ? nil : reader }

  func isReading(_ metric: BuiltinMetric) -> Bool { isThisDeviceReader && reading.contains(metric) }

  func observe() async {
    let main = stores.main
    await designation.run {
      main.observeReads { transaction in try HealthSettings.designation(in: transaction) }
    } onValue: { designation in
      follow(designation)
    }
  }

  private func follow(_ designation: HealthReaderDesignation?) {
    guard let designation, let device = environment.device, designation.device != device.id, !reading.isEmpty else { return }
    environment.preferences.metrics = []
    reading = []
  }

  func set(_ metric: BuiltinMetric, reading isOn: Bool) async {
    guard environment.canRead, busy == nil else { return }
    busy = metric
    defer { busy = nil }
    failure = nil
    if isOn {
      await turnOn(metric, takingOver: false)
    } else {
      await turnOff(metric)
    }
  }

  func confirmTakeover() async {
    guard let takeover, environment.canRead, busy == nil else { return }
    self.takeover = nil
    busy = takeover.metric
    defer { busy = nil }
    failure = nil
    await turnOn(takeover.metric, takingOver: true)
  }

  func cancelTakeover() {
    takeover = nil
  }

  func importNow() async {
    guard !isImporting else { return }
    isImporting = true
    defer { isImporting = false }
    outcome = await HealthImportRunner(environment: environment, stores: stores, clock: clock).run()
    reading = environment.preferences.metrics
  }

  /// Whether a metric this device reads has nothing from Health in the window, which is how a refused permission looks.
  func showsNoData(_ metric: BuiltinMetric, in series: MetricSeries?) -> Bool {
    guard isReading(metric), !isImporting else { return false }
    return !(series?.days.contains { $0.value?.source == .imported } ?? false)
  }

  private func turnOn(_ metric: BuiltinMetric, takingOver: Bool) async {
    guard let device = environment.device, let source = environment.source else { return }
    do {
      let current = try await stores.main.read { transaction in try HealthSettings.designation(in: transaction) }
      if let current, current.device != device.id, !takingOver {
        takeover = Takeover(metric: metric, current: current)
        return
      }
      try await source.requestReading([metric.healthSource])
      let now = MemoirClock.millis(clock.now())
      let claim = try await stores.main.write { transaction in try HealthSettings.claim(device, takingOver: takingOver, atMillis: now, in: &transaction) }
      if case .heldByAnother(let holder) = claim {
        takeover = Takeover(metric: metric, current: holder)
        return
      }
    } catch {
      failure = PresentedError(error)
      return
    }
    environment.preferences.metrics.insert(metric)
    reading = environment.preferences.metrics
    await importNow()
  }

  private func turnOff(_ metric: BuiltinMetric) async {
    environment.preferences.metrics.remove(metric)
    reading = environment.preferences.metrics
    guard reading.isEmpty, let device = environment.device else { return }
    do {
      _ = try await stores.main.write { transaction in try HealthSettings.release(device, in: &transaction) }
      try await HealthImport.forgetLocalState(in: stores)
    } catch {
      failure = PresentedError(error)
    }
  }
}
