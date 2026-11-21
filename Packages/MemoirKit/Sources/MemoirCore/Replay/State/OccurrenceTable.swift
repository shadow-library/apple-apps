import Foundation

/// Values keyed by occurrence and grouped by date, so a day or a window of days is read without scanning the whole history.
public struct OccurrenceTable<Value: Sendable & Hashable>: Sendable, Hashable {
  private var byDate: [LocalDate: [UUID: Value]] = [:]
  private var dates: [LocalDate] = []
  public private(set) var count = 0

  public init() {}

  public internal(set) subscript(occurrence: Occurrence) -> Value? {
    get { byDate[occurrence.date]?[occurrence.quest] }
    set {
      guard let newValue else {
        removeValue(at: occurrence)
        return
      }
      if byDate[occurrence.date] == nil { insertDate(occurrence.date) }
      if byDate[occurrence.date, default: [:]].updateValue(newValue, forKey: occurrence.quest) == nil { count += 1 }
    }
  }

  @discardableResult
  mutating func removeValue(at occurrence: Occurrence) -> Value? {
    guard let removed = byDate[occurrence.date]?.removeValue(forKey: occurrence.quest) else { return nil }
    count -= 1
    if byDate[occurrence.date]?.isEmpty == true {
      byDate[occurrence.date] = nil
      dates.remove(at: firstIndex(atOrAfter: occurrence.date))
    }
    return removed
  }

  public var earliestDate: LocalDate? { dates.first }

  /// The day's values in quest-id order.
  public func entries(on date: LocalDate) -> [(occurrence: Occurrence, value: Value)] {
    (byDate[date] ?? [:]).sorted { $0.key.uuidString < $1.key.uuidString }.map { (occurrence: Occurrence(quest: $0.key, date: date), value: $0.value) }
  }

  /// The day's values in no particular order, for readers that sort or count them themselves.
  func unorderedEntries(on date: LocalDate) -> [(occurrence: Occurrence, value: Value)] {
    (byDate[date] ?? [:]).map { (occurrence: Occurrence(quest: $0.key, date: date), value: $0.value) }
  }

  func unorderedEntries(from start: LocalDate, through end: LocalDate) -> [(occurrence: Occurrence, value: Value)] {
    guard start <= end else { return [] }
    var entries = [(occurrence: Occurrence, value: Value)]()
    var index = firstIndex(atOrAfter: start)
    while index < dates.count, dates[index] <= end {
      entries += unorderedEntries(on: dates[index])
      index += 1
    }
    return entries
  }

  public func count(on date: LocalDate, where isIncluded: (Value) -> Bool) -> Int {
    byDate[date]?.values.count(where: isIncluded) ?? 0
  }

  /// Values on the days from `start` through `end`, in date order.
  public func entries(from start: LocalDate, through end: LocalDate) -> [(occurrence: Occurrence, value: Value)] {
    guard start <= end else { return [] }
    var entries = [(occurrence: Occurrence, value: Value)]()
    var index = firstIndex(atOrAfter: start)
    while index < dates.count, dates[index] <= end {
      entries += self.entries(on: dates[index])
      index += 1
    }
    return entries
  }

  public var all: [(occurrence: Occurrence, value: Value)] {
    dates.flatMap { entries(on: $0) }
  }

  private mutating func insertDate(_ date: LocalDate) {
    if let last = dates.last, last < date { return dates.append(date) }
    dates.insert(date, at: firstIndex(atOrAfter: date))
  }

  private func firstIndex(atOrAfter date: LocalDate) -> Int {
    var low = 0
    var high = dates.count
    while low < high {
      let middle = (low + high) / 2
      if dates[middle] < date { low = middle + 1 } else { high = middle }
    }
    return low
  }
}

/// Entries in date order, then quest-id order, so equal tables encode alike; an occurrence listed twice is refused.
extension OccurrenceTable: Codable where Value: Codable {
  private struct Entry: Codable {
    let quest: UUID
    let date: LocalDate
    let value: Value
  }

  public init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var table = OccurrenceTable()
    while !container.isAtEnd {
      let entry = try container.decode(Entry.self)
      let occurrence = Occurrence(quest: entry.quest, date: entry.date)
      guard table[occurrence] == nil else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "The occurrence \(entry.quest) on \(entry.date) is listed twice.")
      }
      table[occurrence] = entry.value
    }
    self = table
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.unkeyedContainer()
    for entry in all { try container.encode(Entry(quest: entry.occurrence.quest, date: entry.occurrence.date, value: entry.value)) }
  }
}
