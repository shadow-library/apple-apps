import SwiftUI

nonisolated public enum ShadowTimelineOrder: Hashable, Sendable {
  case newestFirst
  case oldestFirst
}

nonisolated public struct ShadowDayGroup<Element> {
  public let day: Date
  public let elements: [Element]
}

nonisolated extension Sequence {
  public func shadowGroupedByDay(date: (Element) -> Date, order: ShadowTimelineOrder = .newestFirst, calendar: Calendar = .current) -> [ShadowDayGroup<Element>] {
    let ordered = enumerated().sorted { lhs, rhs in
      let (left, right) = (date(lhs.element), date(rhs.element))
      if left == right { return lhs.offset < rhs.offset }
      return order == .newestFirst ? left > right : left < right
    }
    var groups: [ShadowDayGroup<Element>] = []
    for (_, element) in ordered {
      let day = calendar.startOfDay(for: date(element))
      if let last = groups.last, last.day == day {
        groups[groups.count - 1] = ShadowDayGroup(day: day, elements: last.elements + [element])
      } else {
        groups.append(ShadowDayGroup(day: day, elements: [element]))
      }
    }
    return groups
  }
}

nonisolated public enum ShadowTimelineStatus: Hashable, Sendable, CaseIterable {
  case completed
  case current
  case upcoming
  case failed

  var defaultSymbol: String? {
    switch self {
    case .completed: "checkmark"
    case .failed: "xmark"
    case .current, .upcoming: nil
    }
  }
}

extension EnvironmentValues {
  @Entry fileprivate var shadowTimelineIsLast = false
}

public struct ShadowTimeline<Element: Identifiable, Row: View>: View {
  private enum Entry: Identifiable {
    case day(Date, Text)
    case item(Element)

    var id: AnyHashable {
      switch self {
      case .day(let date, _): AnyHashable(date)
      case .item(let element): AnyHashable(element.id)
      }
    }
  }

  private let entries: [Entry]
  private let row: (Element) -> Row

  public init(_ elements: [Element], @ViewBuilder row: @escaping (Element) -> Row) {
    entries = elements.map(Entry.item)
    self.row = row
  }

  public init(_ groups: [ShadowDayGroup<Element>], dayTitle: (Date) -> Text, @ViewBuilder row: @escaping (Element) -> Row) {
    entries = groups.flatMap { group in [Entry.day(group.day, dayTitle(group.day))] + group.elements.map(Entry.item) }
    self.row = row
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
        switch entry {
        case .day(_, let title): ShadowTimelineDayHeader(title: title, isFirst: index == 0)
        case .item(let element): row(element).environment(\.shadowTimelineIsLast, index == entries.count - 1)
        }
      }
    }
  }
}

private struct ShadowTimelineDayHeader: View {
  let title: Text
  let isFirst: Bool

  @ScaledMetric(relativeTo: .body) private var marker = ShadowDensity.current == .touch ? 20 : 16

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.space3) {
      Capsule()
        .fill(ShadowColor.borderDefault)
        .frame(width: 2)
        .frame(width: marker)
        .opacity(isFirst ? 0 : 1)
      title
        .shadowFont(.sectionHeader)
        .fontWeight(.semibold)
        .foregroundStyle(ShadowColor.textSecondary)
        .padding(.bottom, Spacing.space2)
        .accessibilityAddTraits(.isHeader)
    }
  }
}

public struct ShadowTimelineItem<Content: View>: View {
  private let status: ShadowTimelineStatus
  private let title: Text
  private let detail: Text?
  private let time: Text?
  private let systemImage: String?
  private let statusLabel: Text?
  private let content: Content

  @Environment(\.shadowTimelineIsLast) private var isLast
  @ScaledMetric(relativeTo: .body) private var marker = ShadowDensity.current == .touch ? 20 : 16

  public init(
    status: ShadowTimelineStatus, title: Text, detail: Text? = nil, time: Text? = nil, systemImage: String? = nil, statusLabel: Text? = nil, @ViewBuilder content: () -> Content
  ) {
    self.status = status
    self.title = title
    self.detail = detail
    self.time = time
    self.systemImage = systemImage
    self.statusLabel = statusLabel
    self.content = content()
  }

  public var body: some View {
    HStack(alignment: .top, spacing: Spacing.space3) {
      VStack(spacing: Spacing.space05) {
        ShadowTimelineMarker(status: status, systemImage: systemImage, diameter: marker)
        if !isLast { Capsule().fill(ShadowColor.borderDefault).frame(width: 2).frame(maxHeight: .infinity) }
      }
      .frame(width: marker)
      VStack(alignment: .leading, spacing: Spacing.space05) {
        VStack(alignment: .leading, spacing: Spacing.space05) {
          title
            .shadowFont(.body)
            .fontWeight(.semibold)
            .foregroundStyle(titleColor)
          meta
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusLabel ?? Text(verbatim: ""))
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.bottom, isLast ? 0 : Spacing.space4)
    }
  }

  private var titleColor: Color {
    switch status {
    case .failed: ShadowColor.destructiveLabel
    case .upcoming: ShadowColor.textSecondary
    case .completed, .current: ShadowColor.textPrimary
    }
  }

  @ViewBuilder
  private var meta: some View {
    switch (detail, time) {
    case (let detail?, let time?):
      ViewThatFits(in: .horizontal) {
        Text("\(detail)\u{00A0}·\u{00A0}\(time)").lineLimit(1)
        VStack(alignment: .leading, spacing: 0) {
          detail
          time
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    case (let detail?, nil): detail
    case (nil, let time?): time
    case (nil, nil): EmptyView()
    }
  }
}

extension ShadowTimelineItem where Content == EmptyView {
  public init(status: ShadowTimelineStatus, title: Text, detail: Text? = nil, time: Text? = nil, systemImage: String? = nil, statusLabel: Text? = nil) {
    self.init(status: status, title: title, detail: detail, time: time, systemImage: systemImage, statusLabel: statusLabel) { EmptyView() }
  }
}

private struct ShadowTimelineMarker: View {
  let status: ShadowTimelineStatus
  let systemImage: String?
  let diameter: CGFloat

  private var glyph: String? { systemImage ?? status.defaultSymbol }

  var body: some View {
    ZStack {
      switch status {
      case .completed: disc(ShadowColor.successSolid, glyph: ShadowColor.successOnSolid)
      case .failed: disc(ShadowColor.dangerSolid, glyph: ShadowColor.dangerOnSolid)
      case .current:
        if glyph == nil {
          Circle().fill(ShadowColor.accentSoft)
          Circle().fill(ShadowColor.accent).padding(diameter * 0.2)
        } else {
          disc(ShadowColor.accent, glyph: ShadowColor.onAccent)
        }
      case .upcoming:
        Circle().strokeBorder(ShadowColor.borderStrong, lineWidth: 2)
        if let glyph { symbol(glyph, color: ShadowColor.textSecondary) }
      }
    }
    .frame(width: diameter, height: diameter)
    .accessibilityHidden(true)
  }

  private func disc(_ fill: Color, glyph color: Color) -> some View {
    ZStack {
      Circle().fill(fill)
      if let glyph { symbol(glyph, color: color) }
    }
  }

  private func symbol(_ name: String, color: Color) -> some View {
    Image(systemName: name)
      .font(Font.shadow(.caption2).weight(.bold))
      .imageScale(.small)
      .foregroundStyle(color)
  }
}
