import ShadowDesignSystem
import SwiftUI

struct DatePickerPage: View {
  private static let calendar = Calendar(identifier: .gregorian)
  private static let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 9, minute: 30)) ?? .now

  @State private var starts = start
  @State private var rangeStart = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10)) ?? .now
  @State private var rangeEnd = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)) ?? .now
  @State private var days: Set<DateComponents> = [
    DateComponents(calendar: calendar, year: 2026, month: 11, day: 10), DateComponents(calendar: calendar, year: 2026, month: 11, day: 12),
  ]
  @State private var time = start

  private var bounds: Range<Date> {
    let lower = Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)) ?? Self.start
    return lower..<(Self.calendar.date(byAdding: .year, value: 1, to: lower) ?? lower)
  }

  var body: some View {
    ComponentPage(component: .datePicker) {
      StateSection("Compact", note: "Chips on surface-well open the calendar and clock. On Mac the same value is a field with stepper editing.") {
        FormBlock {
          FormSection {
            DatePicker("Starts", selection: $starts)
            DatePicker("Date only", selection: $starts, displayedComponents: .date)
            DatePicker("Time only", selection: $time, displayedComponents: .hourAndMinute)
          }
        }
        #if os(macOS)
          .datePickerStyle(.stepperField)
        #else
          .datePickerStyle(.compact)
        #endif
      }
      StateSection("Graphical", note: "When the date itself is the task. The system marks the selected day in accent and today in accent text.") {
        DatePicker("Starts", selection: $starts, displayedComponents: .date)
          .datePickerStyle(.graphical)
          .labelsHidden()
          .shadowCard()
          #if os(macOS)
            .fixedSize()
          #else
            .frame(maxWidth: 420, alignment: .leading)
          #endif
      }
      StateSection("Range", note: "The end can never precede the start; the end picker is bounded by the start.") {
        FormBlock {
          FormSection {
            DatePicker("From", selection: $rangeStart, displayedComponents: .date)
              .onChange(of: rangeStart) { _, newValue in
                if rangeEnd < newValue { rangeEnd = newValue }
              }
            DatePicker("To", selection: $rangeEnd, in: rangeStart..., displayedComponents: .date)
          } footer: {
            Text("Ranges are inclusive.")
          }
        }
      }
      #if !os(macOS)
        StateSection("Several days", note: "MultiDatePicker marks every chosen day the same way as the selected day.") {
          MultiDatePicker("Reading days", selection: $days, in: bounds)
            .shadowCard()
            .frame(maxWidth: 420, alignment: .leading)
        }
      #endif
      StateSection("Disabled") {
        FormBlock {
          FormSection {
            DisabledControlRow("Starts") {
              DatePicker("Starts", selection: $starts)
            }
          }
        }
      }
    }
  }
}
