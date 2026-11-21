import ShadowCore
import ShadowStore

public enum ImportedDayWrite: Sendable, Equatable {
  case written
  case unchanged
  case unreadable
}

/// The two writers of a metric's day. Each edits only its own register, so the owner's entry and the Health import never overwrite each other, on one
/// device or across two.
public enum MetricDays {
  /// Sets or, with `nil`, clears the owner's entry. A day the owner removed comes back with the new entry, even when the removal was made on a device
  /// whose writes have not arrived yet: a new entry is the owner saying the day counts.
  @discardableResult
  public static func enter<Class: MetricClass>(_ entry: MetricEntry?, for metric: MetricID<Class>, on date: LocalDate, in transaction: inout WriteTransaction)
    throws(MemoirRecordError) -> Bool
  {
    let ref = MemoirKey.metricDay(Class.syncClass, metric: metric.recordUUID, date: date).ref
    switch try reading(ref, in: transaction) as MemoirReading<MemoirEntry<MetricDayRecord<Class>>> {
    case .absent:
      guard let entry else { return false }
      try MetricDayRecord(metric: metric, date: date, entry: entry).create(in: &transaction)
      return true
    case .unreadable(let reason):
      throw .unreadable(ref, reason)
    case .readable(let current):
      var written = false
      if current.isRemoved, entry != nil {
        try MetricDayRecord<Class>.restore(ref, in: &transaction)
        written = true
      }
      guard current.record.entry != entry else { return written }
      try MetricDayRecord<Class>.edit(ref, in: &transaction) { $0.entry = entry }
      return true
    }
  }

  /// Sets or, with `nil`, clears the Health import. It never restores a day the owner removed, here or on a device whose removal has not arrived yet, and
  /// a day a newer app wrote that this one cannot read is left alone.
  public static func setImported<Class: MetricClass>(_ value: DecimalText?, for metric: MetricID<Class>, on date: LocalDate, in transaction: inout WriteTransaction)
    throws(MemoirRecordError) -> ImportedDayWrite
  {
    let ref = MemoirKey.metricDay(Class.syncClass, metric: metric.recordUUID, date: date).ref
    switch try reading(ref, in: transaction) as MemoirReading<MemoirEntry<MetricDayRecord<Class>>> {
    case .absent:
      guard let value else { return .unchanged }
      try MetricDayRecord(metric: metric, date: date, imported: value).createKeepingRemoval(in: &transaction)
      return .written
    case .unreadable:
      return .unreadable
    case .readable(let current):
      guard current.record.imported != value else { return .unchanged }
      try MetricDayRecord<Class>.edit(ref, in: &transaction) { $0.imported = value }
      return .written
    }
  }

  /// Each day's shown value, the owner's entry over the import, leaving out removed days and days with neither.
  public static func values<Class: MetricClass, Source: RecordSource & ~Copyable>(of metric: MetricID<Class>, in source: borrowing Source) throws(StoreError)
    -> [LocalDate: DecimalText]
  {
    var values = [LocalDate: DecimalText]()
    for entry in try MetricDayRecord<Class>.listing(in: source).entries where !entry.isRemoved && entry.record.metric == metric {
      if let value = entry.record.value { values[entry.record.date] = value }
    }
    return values
  }

  private static func reading<Record: MemoirRecord>(_ ref: EntityRef, in transaction: borrowing WriteTransaction) throws(MemoirRecordError) -> MemoirReading<
    MemoirEntry<Record>
  > {
    do throws(StoreError) {
      return try Record.read(ref, in: transaction)
    } catch {
      throw .store(error)
    }
  }
}
