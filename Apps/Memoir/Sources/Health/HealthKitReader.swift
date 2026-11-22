import Foundation
import MemoirCore

/// MemoirCore's `HealthReader` over a `HealthSampleSource`: totals read once per window, samples dated by the offset where they were recorded (their
/// time-zone metadata, else this device's zone at their start) and their quantities written as exact decimals.
nonisolated struct HealthKitReader: HealthReader {
  let source: any HealthSampleSource
  let deviceZone: @Sendable () -> TimeZone

  init(source: any HealthSampleSource, deviceZone: @escaping @Sendable () -> TimeZone = { TimeZone.current }) {
    self.source = source
    self.deviceZone = deviceZone
  }

  func totals(of quantity: HealthTotal, in windows: [HealthWindow]) async throws(HealthReadError) -> [LocalDate: DecimalText] {
    var totals = [LocalDate: DecimalText]()
    for window in windows {
      guard let sum = try await source.sum(of: quantity, from: Self.date(window.startMillis), to: Self.date(window.endMillis)),
        let value = HealthValueText.decimal(sum, places: HealthValueText.places(of: quantity))
      else { continue }
      totals[window.date] = value
    }
    return totals
  }

  func changes(of kind: HealthSampleKind, after anchor: HealthAnchor?, since startMillis: Int64) async throws(HealthReadError) -> HealthSampleChanges {
    let raw = try await source.changes(of: kind, after: anchor?.data, since: Self.date(startMillis))
    let zone = deviceZone()
    let added = raw.added.compactMap { sample -> HealthSample? in
      guard let start = Self.millis(sample.start), let end = Self.millis(sample.end) else { return nil }
      let offset = (sample.recordedZone ?? zone).secondsFromGMT(for: sample.start) / 60
      let quantity = kind.isInterval ? nil : sample.quantity.flatMap { HealthValueText.decimal($0, places: HealthValueText.places(of: kind)) }
      return HealthSample(id: sample.id, startMillis: start, endMillis: end, utcOffsetMinutes: offset, quantity: quantity)
    }
    return HealthSampleChanges(added: added, deleted: raw.deleted, anchor: HealthAnchor(data: raw.anchor))
  }

  private static func date(_ millis: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
  }

  private static func millis(_ date: Date) -> Int64? {
    Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded(.down))
  }
}
