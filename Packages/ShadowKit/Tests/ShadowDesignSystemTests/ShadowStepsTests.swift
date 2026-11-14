import Foundation
import Testing

@testable import ShadowDesignSystem

@Suite("Steps")
struct ShadowStepsTests {
  @Test("should mark steps before the current one completed and after it upcoming")
  func states() {
    let states = (0..<4).map { ShadowStepState(index: $0, current: 1) }
    #expect(states == [.completed, .current, .upcoming, .upcoming])
  }

  @Test("should count current and completed steps as reached")
  func reached() {
    #expect(ShadowStepState.completed.isReached)
    #expect(ShadowStepState.current.isReached)
    #expect(!ShadowStepState.upcoming.isReached)
  }

  @Test("should number the position from one and clamp out of range indices", arguments: [(-3, 1), (0, 1), (1, 2), (3, 4), (9, 4)])
  func position(index: Int, number: Int) {
    let position = ShadowStepsPosition(index: index, count: 4)
    #expect(position.number == number)
    #expect(position.count == 4)
  }

  @Test("should not crash on zero steps")
  func empty() {
    #expect(ShadowStepsPosition.clamped(2, count: 0) == 0)
    #expect(ShadowStepsPosition(index: 2, count: 0).count == 0)
  }
}

@Suite("Timeline")
struct ShadowTimelineTests {
  private struct Event {
    let name: String
    let date: Date
  }

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
  }

  private func event(_ name: String, day: Int, hour: Int, minute: Int = 0) -> Event {
    let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? .distantPast
    return Event(name: name, date: date)
  }

  private var events: [Event] { [event("b", day: 13, hour: 9), event("d", day: 14, hour: 9), event("a", day: 13, hour: 8), event("c", day: 14, hour: 7)] }

  @Test("should order newest first within and across days")
  func newestFirst() {
    let groups = events.shadowGroupedByDay(date: \.date, order: .newestFirst, calendar: calendar)
    #expect(groups.map { $0.elements.map(\.name) } == [["d", "c"], ["b", "a"]])
    #expect(groups.map(\.day) == groups.map(\.day).sorted(by: >))
  }

  @Test("should order oldest first for a process")
  func oldestFirst() {
    let groups = events.shadowGroupedByDay(date: \.date, order: .oldestFirst, calendar: calendar)
    #expect(groups.map { $0.elements.map(\.name) } == [["a", "b"], ["c", "d"]])
  }

  @Test("should keep input order for identical timestamps")
  func stableTies() {
    let tied = [event("x", day: 14, hour: 9), event("y", day: 14, hour: 9), event("z", day: 14, hour: 9)]
    let groups = tied.shadowGroupedByDay(date: \.date, calendar: calendar)
    #expect(groups.count == 1)
    #expect(groups[0].elements.map(\.name) == ["x", "y", "z"])
  }

  @Test("should split at calendar midnight")
  func midnight() {
    let late = event("late", day: 13, hour: 23, minute: 59)
    let early = event("early", day: 14, hour: 0)
    let groups = [late, early].shadowGroupedByDay(date: \.date, calendar: calendar)
    #expect(groups.count == 2)
  }

  @Test("should return no groups for no events")
  func empty() {
    #expect([Event]().shadowGroupedByDay(date: \.date, calendar: calendar).isEmpty)
  }
}
