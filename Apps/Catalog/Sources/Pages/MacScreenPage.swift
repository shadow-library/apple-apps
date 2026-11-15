import ShadowDesignSystem
import SwiftUI

private enum PulseDestination: Hashable, Identifiable {
  case overview
  case deliveries
  case templates
  case senders
  case channels
  case members

  var id: Self { self }

  var title: String {
    switch self {
    case .overview: "Overview"
    case .deliveries: "Deliveries"
    case .templates: "Templates"
    case .senders: "Senders"
    case .channels: "Channels"
    case .members: "Members"
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .deliveries: "paperplane"
    case .templates: "doc.text"
    case .senders: "server.rack"
    case .channels: "envelope"
    case .members: "person.2"
    }
  }

  var badge: ShadowSidebarBadge? {
    switch self {
    case .deliveries: .alert(3)
    case .templates: .count(24)
    default: nil
    }
  }
}

private enum PulseRange: String, CaseIterable, Identifiable {
  case day = "Day"
  case week = "Week"
  case month = "Month"

  var id: Self { self }
}

private nonisolated enum PulseStatus: Int, Comparable, Sendable {
  case delivered
  case failed
  case queued

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension PulseStatus {
  fileprivate var badge: ShadowBadge {
    switch self {
    case .delivered: ShadowBadge("Delivered", intent: .success, systemImage: "checkmark")
    case .failed: ShadowBadge("Failed", intent: .danger, systemImage: "xmark")
    case .queued: ShadowBadge("Queued", intent: .info, systemImage: "clock")
    }
  }
}

private nonisolated struct PulseDelivery: Identifiable, Hashable, Sendable {
  let id: String
  let channel: String
  let sent: Int
  let status: PulseStatus
  let time: Date

  var template: String { id }

  private static func at(_ hour: Int, _ minute: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: hour, minute: minute)) ?? .distantPast
  }

  static let all: [PulseDelivery] = [
    PulseDelivery(id: "welcome-email", channel: "Email", sent: 1_204, status: .delivered, time: at(9, 42)),
    PulseDelivery(id: "chapter-released", channel: "Email", sent: 8_310, status: .delivered, time: at(9, 30)),
    PulseDelivery(id: "step-up-code", channel: "Email", sent: 61, status: .failed, time: at(9, 12)),
    PulseDelivery(id: "weekly-digest", channel: "Email", sent: 2_977, status: .queued, time: at(8, 0)),
    PulseDelivery(id: "password-reset", channel: "Email", sent: 18, status: .delivered, time: at(7, 51)),
  ]
}

private enum PulseOrganization {
  static let all = [
    ShadowOrganization(id: "shadow-library", name: "Shadow Library", detail: "Pulse · Production"),
    ShadowOrganization(id: "synapse-labs", name: "Synapse Labs", detail: "Pulse · Staging"),
  ]
}

struct MacScreenPage: View {
  @State private var destination: PulseDestination? = .overview
  @State private var compactColumn = NavigationSplitViewColumn.detail
  @State private var organization = PulseOrganization.all[0].id

  var body: some View {
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      List(selection: $destination) {
        Section {
          ForEach([PulseDestination.overview, .deliveries, .templates, .senders]) { item in PulseSidebarRow(item: item) }
        } header: {
          ShadowSidebarHeader("Console")
        }
        Section {
          ForEach([PulseDestination.channels, .members]) { item in PulseSidebarRow(item: item) }
        } header: {
          ShadowSidebarHeader("Settings")
        }
      }
      .shadowListStyle(.sidebar)
      .safeAreaInset(edge: .top) {
        ShadowOrganizationSwitcher("Switch organization", organizations: PulseOrganization.all, selection: $organization)
          .padding(.horizontal, DemoLayout.margin)
          .padding(.vertical, Spacing.space2)
      }
      .navigationTitle("Pulse")
      .shadowColumnWidth(.sidebar)
      .toolbar { CatalogDemoCloseItem() }
    } detail: {
      NavigationStack { PulseOverview() }
    }
  }
}

private struct PulseSidebarRow: View {
  let item: PulseDestination

  var body: some View {
    ShadowSidebarLabel(Text(verbatim: item.title), systemImage: item.systemImage, badge: item.badge)
      .tag(item)
  }
}

private struct PulseOverview: View {
  @State private var range = PulseRange.week
  @State private var query = ""
  @State private var selection: Set<PulseDelivery.ID> = ["step-up-code"]
  @State private var sortOrder: [KeyPathComparator<PulseDelivery>] = [KeyPathComparator(\.time, order: .reverse)]

  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  private var isCompact: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  private var rangePicker: some View {
    Picker("Time range", selection: $range) {
      ForEach(PulseRange.allCases) { option in Text(LocalizedStringKey(option.rawValue)).tag(option) }
    }
    .pickerStyle(.segmented)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        if isCompact { rangePicker.labelsHidden() }
        statistics
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: Spacing.space4) {
            chart.frame(minWidth: 460, maxWidth: .infinity)
            sidebarCards.frame(minWidth: 320, idealWidth: 420, maxWidth: 440)
          }
          VStack(spacing: Spacing.space4) {
            chart
            sidebarCards
          }
        }
        deliveries
      }
      .padding(DemoLayout.margin)
    }
    .catalogScrollAnchor()
    .navigationTitle("Overview")
    .demoSubtitle("Pulse · Production")
    .shadowScreen(.pushed)
    .demoEditorRoleWhenRegular()
    .toolbar {
      if !isCompact {
        ToolbarItem(placement: .primaryAction) { rangePicker.frame(minWidth: 190) }
      }
      ToolbarItemGroup(placement: .primaryAction) {
        Button("Refresh", systemImage: "arrow.clockwise") {}
          .help("Refresh")
          .shadowBarItem()
        Menu("More", systemImage: "ellipsis") {
          Button("Export CSV…", systemImage: "square.and.arrow.up") {}
          Button("Pause sending", systemImage: "pause") {}
        }
        .help("More")
        .shadowBarItem()
      }
    }
    #if os(macOS)
      .searchable(text: $query, placement: .toolbar, prompt: "Search deliveries")
    #else
      .searchable(text: $query, prompt: "Search deliveries")
    #endif
  }

  private var statistics: some View {
    ShadowStatisticGrid(minimumWidth: 160) {
      ShadowStatistic("Sent this week", value: Text("8,900"), delta: ShadowDeltaBadge(ShadowDelta(change: 12), unit: .percent))
      ShadowStatistic("Delivered", value: Text("98.4%"), delta: ShadowDeltaBadge(ShadowDelta(change: 0.6, fractionDigits: 1), unit: .suffix("pt")))
      ShadowStatistic("Failed today", value: Text("61"), delta: ShadowDeltaBadge(ShadowDelta(change: 18, higherIsBetter: false)))
      ShadowStatistic("Median send time", value: Text("1.2 s"), delta: ShadowDeltaBadge(ShadowDelta(change: -0.3, higherIsBetter: false, fractionDigits: 1), unit: .suffix("s")))
    }
  }

  private var chart: some View {
    ShadowCard {
      OutcomeBars()
      ShadowChartLegend(["Delivered", "Opened"])
    } header: {
      ShadowCardHeader("Daily notification volume", subtitle: "This week, by outcome")
    }
  }

  private var sidebarCards: some View {
    VStack(spacing: Spacing.space4) {
      ShadowCallout("Email delivery failed", message: "Resend rejected 61 step-up codes since 09:12. Check the sender domain.", intent: .danger)
      ShadowCard {
        senderDetails
        Button("Open sender") {}
          .buttonStyle(.shadowBordered)
      } header: {
        ShadowCardHeader("Senders")
      }
    }
  }

  @ViewBuilder
  private var senderDetails: some View {
    #if os(macOS)
      Form { senderRows }
        .formStyle(.columns)
        .frame(maxWidth: .infinity, alignment: .leading)
    #else
      VStack(spacing: 0) { senderRows }
    #endif
  }

  @ViewBuilder
  private var senderRows: some View {
    ShadowLabeledContent("Resend") { ShadowBadge("Degraded", intent: .warning, systemImage: "exclamationmark.triangle") }
    ShadowLabeledContent("Domain", identifier: "mail.shadowlibrary.app")
    ShadowLabeledContent("Last check", value: "2 min ago")
  }

  private var deliveries: some View {
    ShadowTable(PulseDelivery.all.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
      TableColumn(Text("Template").shadowTableHeader(), value: \.template) { ShadowTableIdentifier($0.template) }
        .width(min: 168, ideal: 240)
      TableColumn(Text("Channel").shadowTableHeader(), value: \.channel) { Text(verbatim: $0.channel) }
        .width(min: 72, ideal: 120)
      TableColumn(Text("Sent").shadowTableHeader(), value: \.sent) { ShadowTableNumber(Text($0.sent, format: .number)) }
        .width(min: 64, ideal: 88)
        .alignment(.trailing)
      TableColumn(Text("Status").shadowTableHeader(), value: \.status) { $0.status.badge }
        .width(min: 104, ideal: 140)
      TableColumn(Text("Time").shadowTableHeader(), value: \.time) { ShadowTableNumber(Text($0.time, format: .dateTime.hour().minute())) }
        .width(min: 56, ideal: 72)
        .alignment(.trailing)
    } compact: { delivery in
      ShadowListRow(
        title: Text(verbatim: delivery.template), subtitle: Text("\(delivery.sent, format: .number) sent · \(delivery.time, format: .dateTime.hour().minute())"),
        isSelected: selection.contains(delivery.id), trailing: delivery.status.badge)
    }
    .demoTableFrame(.fitsContent(estimatedRows: PulseDelivery.all.count))
  }
}
