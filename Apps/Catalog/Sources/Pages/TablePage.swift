import ShadowDesignSystem
import SwiftUI

private nonisolated enum DeliveryStatus: Int, Comparable, CaseIterable {
  case delivered
  case failed
  case queued

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

private nonisolated struct Delivery: Identifiable, Hashable, Sendable {
  let id: String
  let status: DeliveryStatus
  let sent: Int
  let time: Date

  var template: String { id }

  static func at(_ hour: Int, _ minute: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: hour, minute: minute)) ?? .distantPast
  }

  static let sample: [Delivery] = [
    Delivery(id: "welcome-email", status: .delivered, sent: 1_204, time: at(9, 42)),
    Delivery(id: "chapter-released", status: .delivered, sent: 8_310, time: at(9, 30)),
    Delivery(id: "step-up-code", status: .failed, sent: 61, time: at(9, 12)),
    Delivery(id: "weekly-digest", status: .queued, sent: 2_977, time: at(8, 0)),
    Delivery(id: "password-reset", status: .delivered, sent: 412, time: at(7, 51)),
  ]

  static let long: [Delivery] = [
    Delivery(id: "chapter-released-notification-the-ninth-archive-eu-west-1-2026-11-14", status: .delivered, sent: 128_904, time: at(9, 42)),
    Delivery(id: "a3f9c2e1-77b4-4c1d-9a5e-0d2f6b8e4c11-retry-3", status: .failed, sent: 3, time: at(9, 30)),
    Delivery(id: "weekly-digest", status: .queued, sent: 2_977, time: at(8, 0)),
  ]

  static let many: [Delivery] = (0..<24).map { index in
    Delivery(
      id: "delivery-\(String(format: "%03d", 240 - index))", status: DeliveryStatus.allCases[index % 3], sent: 40 + index * 137 % 900, time: at(9 - index / 6, 59 - index * 2 % 60))
  }
}

extension DeliveryStatus {
  fileprivate var badge: ShadowBadge {
    switch self {
    case .delivered: ShadowBadge("Delivered", intent: .success, systemImage: "checkmark")
    case .failed: ShadowBadge("Failed", intent: .danger, systemImage: "xmark")
    case .queued: ShadowBadge("Queued", intent: .info, systemImage: "clock")
    }
  }
}

private struct DeliveryTable: View {
  let rows: [Delivery]
  var isLoading = false
  var sizing: DemoTableSizing
  var takesSnapshotFocus = false
  @State var sortOrder: [KeyPathComparator<Delivery>] = [KeyPathComparator(\.time, order: .reverse)]
  @State var selection: Set<Delivery.ID> = []

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(
    rows: [Delivery], isLoading: Bool = false, sizing: DemoTableSizing? = nil, sortedBy: [KeyPathComparator<Delivery>]? = nil, selected: Set<Delivery.ID> = [],
    takesSnapshotFocus: Bool = false
  ) {
    self.rows = rows
    self.takesSnapshotFocus = takesSnapshotFocus
    self.isLoading = isLoading
    self.sizing = sizing ?? .fitsContent(estimatedRows: rows.count)
    _sortOrder = State(initialValue: sortedBy ?? [KeyPathComparator(\.time, order: .reverse)])
    _selection = State(initialValue: selected)
  }

  private var isList: Bool { ShadowTableLayout(horizontalSizeClass: horizontalSizeClass, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) == .list }

  private var compactSort: ShadowTableCompactSort<Delivery> {
    ShadowTableCompactSort(
      Text("Sort"),
      options: [
        ShadowTableSortOption(Text("Template"), comparator: KeyPathComparator(\.template)),
        ShadowTableSortOption(Text("Status"), comparator: KeyPathComparator(\.status)),
        ShadowTableSortOption(Text("Sent"), comparator: KeyPathComparator(\.sent, order: .reverse)),
        ShadowTableSortOption(Text("Time"), comparator: KeyPathComparator(\.time, order: .reverse)),
      ])
  }

  var body: some View {
    ShadowTable(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder, isLoading: isLoading, loadingLabel: "Loading deliveries", compactSort: compactSort) {
      TableColumn(Text("Template").shadowTableHeader(), value: \.template) { ShadowTableIdentifier($0.template).shadowTableCell(row: $0) }
        .width(min: 180, ideal: 240)
      TableColumn(Text("Status").shadowTableHeader(), value: \.status) { $0.status.badge.shadowTableCell(row: $0) }
        .width(min: 96, ideal: 120)
      TableColumn(Text("Sent").shadowTableHeader(), value: \.sent) { ShadowTableNumber(Text($0.sent, format: .number)).shadowTableCell(row: $0) }
        .width(min: 64, ideal: 88)
        .alignment(.trailing)
      TableColumn(Text("Time").shadowTableHeader(), value: \.time) { ShadowTableNumber(Text($0.time, format: .dateTime.hour().minute())).shadowTableCell(row: $0) }
        .width(min: 56, ideal: 72)
        .alignment(.trailing)
    } compact: { delivery in
      ShadowListRow(
        title: Text(verbatim: delivery.template).monospaced(), subtitle: Text("\(delivery.sent, format: .number) sent · \(delivery.time, format: .dateTime.hour().minute())"),
        isSelected: selection.contains(delivery.id), trailing: delivery.status.badge
      )
      .shadowListRowSingleLineTitle(truncationMode: .middle)
    } empty: {
      ShadowContentUnavailable("No deliveries yet", message: "Sent emails and push notifications show up here.")
    }
    .contextMenu(forSelectionType: Delivery.ID.self) { ids in
      if !ids.isEmpty {
        Button("Resend", systemImage: "arrow.clockwise") {}
        Button("Copy ID", systemImage: "doc.on.doc") {}
      }
    } primaryAction: { _ in
    }
    #if os(iOS)
      .environment(\.editMode, .constant(isList && !selection.isEmpty ? .active : .inactive))
    #endif
    .modifier(SnapshotFocusIf(isEnabled: takesSnapshotFocus))
    .demoTableFrame(sizing)
  }
}

struct TablePage: View {
  var body: some View {
    ComponentPage(component: .table) {
      StateSection(
        "Deliveries",
        note:
          "Mac and iPad use the native Table with sortable headers; selection is the native band, accent while the table is focused and grey otherwise. Identifiers use the mono face and numbers and times are tabular and right-aligned. iPhone collapses to a list with the rest as subtitle and a trailing badge, and a Sort menu replaces the headers."
      ) {
        DeliveryTable(rows: Delivery.sample)
      }
      .shadowColumnSpan(.full)
      StateSection("Selected", note: "Selection fills the row; a row can be picked with the pointer or the keyboard, and the context menu acts on the selection.") {
        DeliveryTable(rows: Delivery.sample, selected: ["step-up-code"], takesSnapshotFocus: true)
      }
      .shadowColumnSpan(.full)
      StateSection("Multiple selection", note: "Shift and Command extend the selection on Mac; iPhone enters selection mode.") {
        DeliveryTable(rows: Delivery.sample, selected: ["chapter-released", "step-up-code"])
      }
      .shadowColumnSpan(.full)
      StateSection(
        "Sorted by template",
        note: "Clicking a header sorts by it and a second click reverses the order. The caller sorts the rows with the same sort order; on iPhone the Sort menu changes it."
      ) {
        DeliveryTable(rows: Delivery.sample, sortedBy: [KeyPathComparator(\.template)])
      }
      .shadowColumnSpan(.full)
      StateSection(
        "Long identifiers",
        note: "In table cells identifiers stay on one line and truncate in the middle so the ends, which differ, stay readable; the iPhone list rows do the same."
      ) {
        DeliveryTable(rows: Delivery.long)
      }
      .shadowColumnSpan(.full)
      StateSection("Scrolling", note: "The table owns its scrolling. Rows load as people reach the end; there is no pagination.") {
        DeliveryTable(rows: Delivery.many, sizing: .scrolling(visibleRows: 6))
      }
      .shadowColumnSpan(.full)
      StateSection(
        "Loading",
        note: "Placeholder rows are drawn redacted in the table’s own columns, so the skeleton follows the headers and keeps the table’s size until the first response."
      ) {
        DeliveryTable(rows: Delivery.sample, isLoading: true)
      }
      .shadowColumnSpan(.full)
      StateSection("Empty", note: "The headers stay and the body says what is missing.") {
        DeliveryTable(rows: [], sizing: .rows(ShadowDensity.current == .compact ? 8 : 5))
      }
      .shadowColumnSpan(.full)
    }
  }
}

private struct SnapshotFocusIf: ViewModifier {
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if isEnabled {
      content.catalogSnapshotFocus()
    } else {
      content
    }
  }
}
