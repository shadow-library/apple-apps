import SwiftUI

nonisolated public enum ShadowTableLayout: Hashable, Sendable {
  case grid
  case list

  public init(horizontalSizeClass: UserInterfaceSizeClass?, isAccessibilitySize: Bool = false) {
    self = horizontalSizeClass == .compact || isAccessibilitySize ? .list : .grid
  }
}

nonisolated public enum ShadowTableMetrics {
  public static let skeletonRowCount = 5

  static func headerHeight(density: ShadowDensity = .current) -> CGFloat {
    density == .touch ? ShadowMetrics.rowTouch : ShadowMetrics.rowMac
  }

  static func alternatesRows(density: ShadowDensity = .current) -> Bool {
    density == .compact
  }

  public static func skeletonRows(_ requested: Int) -> Int {
    min(max(requested, 1), 12)
  }
}

nonisolated public struct ShadowTableSortOption<Value> {
  public let title: Text
  public let comparator: KeyPathComparator<Value>

  public init(_ title: Text, comparator: KeyPathComparator<Value>) {
    self.title = title
    self.comparator = comparator
  }
}

nonisolated public struct ShadowTableCompactSort<Value> {
  public let title: Text
  public let options: [ShadowTableSortOption<Value>]

  public init(_ title: Text, options: [ShadowTableSortOption<Value>]) {
    self.title = title
    self.options = options
  }

  public static func selecting(_ option: KeyPathComparator<Value>, from current: [KeyPathComparator<Value>]) -> [KeyPathComparator<Value>] {
    guard var first = current.first, first.keyPath == option.keyPath else { return [option] }
    first.order = first.order == .forward ? .reverse : .forward
    return [first]
  }

  public static func isActive(_ option: KeyPathComparator<Value>, in current: [KeyPathComparator<Value>]) -> Bool {
    current.first?.keyPath == option.keyPath
  }
}

/// Rows are displayed in the order given, so sort them with `sorted(using: sortOrder)` before passing them in.
/// Mac selection uses the system accent; selection-row applies to custom lists.
/// iPhone lists select only in edit mode, so give the screen an `EditButton`.
/// Apply `.contextMenu(forSelectionType:menu:primaryAction:)` to the table for the context menu and the double-click, Return or tap action.
public struct ShadowTable<Value: Identifiable, Columns: TableColumnContent, Compact: View, Empty: View>: View
where Columns.TableRowValue == Value, Columns.TableColumnSortComparator == KeyPathComparator<Value> {
  private let rows: [Value]
  private let selection: Binding<Set<Value.ID>>
  private let sortOrder: Binding<[KeyPathComparator<Value>]>
  private let isLoading: Bool
  private let loadingLabel: LocalizedStringKey?
  private let skeletonColumns: [CGFloat]
  private let compactSort: ShadowTableCompactSort<Value>?
  private let columns: Columns
  private let compact: (Value) -> Compact
  private let empty: Empty

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  public init(
    _ rows: [Value],
    selection: Binding<Set<Value.ID>>,
    sortOrder: Binding<[KeyPathComparator<Value>]>,
    isLoading: Bool = false,
    loadingLabel: LocalizedStringKey? = nil,
    skeletonColumns: [CGFloat] = [0.4, 0.2, 0.15, 0.15],
    compactSort: ShadowTableCompactSort<Value>? = nil,
    @TableColumnBuilder<Value, KeyPathComparator<Value>> columns: () -> Columns,
    @ViewBuilder compact: @escaping (Value) -> Compact,
    @ViewBuilder empty: () -> Empty
  ) {
    self.rows = rows
    self.selection = selection
    self.sortOrder = sortOrder
    self.isLoading = isLoading
    self.loadingLabel = loadingLabel
    self.skeletonColumns = skeletonColumns
    self.compactSort = compactSort
    self.columns = columns()
    self.compact = compact
    self.empty = empty()
  }

  private var layout: ShadowTableLayout {
    ShadowTableLayout(horizontalSizeClass: horizontalSizeClass, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }

  public var body: some View {
    content
      .environment(\.defaultMinListRowHeight, ShadowMetrics.rowHeight)
      .environment(\.shadowMaterialLayer, .content)
      .background(ShadowColor.surfaceCard)
  }

  @ViewBuilder
  private var content: some View {
    switch layout {
    case .grid:
      Table(isLoading ? [] : rows, selection: selection, sortOrder: sortOrder) { columns }
        .tableStyle(.inset)
        .modifier(ShadowTableBackdrop(isEmpty: rows.isEmpty || isLoading))
        .scrollContentBackground(.hidden)
        .overlay {
          Group {
            if isLoading {
              ShadowTableSkeleton(columns: skeletonColumns, label: loadingLabel)
            } else if rows.isEmpty {
              empty
            }
          }
          .padding(.top, ShadowTableMetrics.headerHeight())
        }
    case .list:
      Group {
        if isLoading {
          ShadowTableSkeleton(columns: skeletonColumns, isList: true, label: loadingLabel)
        } else {
          List(rows, selection: selection) { row in compact(row) }
            .shadowListStyle(.plain)
        }
      }
      .contentMargins(.top, 0, for: .scrollContent)
      .safeAreaInset(edge: .top, spacing: 0) {
        if let compactSort { ShadowTableSortMenu(sort: compactSort, sortOrder: sortOrder).disabled(isLoading) }
      }
      .overlay {
        if rows.isEmpty && !isLoading { empty }
      }
    }
  }
}

private struct ShadowTableSortMenu<Value>: View {
  let sort: ShadowTableCompactSort<Value>
  let sortOrder: Binding<[KeyPathComparator<Value>]>

  var body: some View {
    HStack {
      Spacer()
      Menu {
        ForEach(sort.options.indices, id: \.self) { index in
          let option = sort.options[index]
          let isActive = ShadowTableCompactSort.isActive(option.comparator, in: sortOrder.wrappedValue)
          Button {
            sortOrder.wrappedValue = ShadowTableCompactSort.selecting(option.comparator, from: sortOrder.wrappedValue)
          } label: {
            if isActive {
              Label {
                option.title
              } icon: {
                Image(systemName: sortOrder.wrappedValue.first?.order == .forward ? "chevron.up" : "chevron.down")
              }
            } else {
              option.title
            }
          }
        }
      } label: {
        Label {
          sort.title
        } icon: {
          Image(systemName: "arrow.up.arrow.down")
        }
        .shadowFont(.subheadline)
      }
      .buttonStyle(.shadowPlain)
      .controlSize(.small)
    }
    .padding(.horizontal, ShadowListMetrics().horizontalPadding)
    .padding(.vertical, Spacing.space1)
    .background(ShadowColor.surfaceCard)
  }
}

extension ShadowTable where Empty == EmptyView {
  public init(
    _ rows: [Value],
    selection: Binding<Set<Value.ID>>,
    sortOrder: Binding<[KeyPathComparator<Value>]>,
    isLoading: Bool = false,
    loadingLabel: LocalizedStringKey? = nil,
    skeletonColumns: [CGFloat] = [0.4, 0.2, 0.15, 0.15],
    compactSort: ShadowTableCompactSort<Value>? = nil,
    @TableColumnBuilder<Value, KeyPathComparator<Value>> columns: () -> Columns,
    @ViewBuilder compact: @escaping (Value) -> Compact
  ) {
    self.init(
      rows, selection: selection, sortOrder: sortOrder, isLoading: isLoading, loadingLabel: loadingLabel, skeletonColumns: skeletonColumns, compactSort: compactSort,
      columns: columns, compact: compact
    ) {
      EmptyView()
    }
  }
}

public struct ShadowTableSkeleton: View {
  private let columns: [CGFloat]
  private let isList: Bool
  private let rows: Int
  private let label: LocalizedStringKey?

  @ScaledMetric(relativeTo: .body) private var rowHeight = ShadowMetrics.rowHeight

  public init(columns: [CGFloat], isList: Bool = false, rows: Int = ShadowTableMetrics.skeletonRowCount, label: LocalizedStringKey? = nil) {
    self.columns = columns.isEmpty ? [1] : columns.map { min(max($0, 0.05), 1) }
    self.isList = isList
    self.rows = ShadowTableMetrics.skeletonRows(rows)
    self.label = label
  }

  public var body: some View {
    Group {
      if isList {
        List(0..<rows, id: \.self) { index in
          ShadowTableSkeletonListRow()
            .listRowSeparator(index == rows - 1 ? .hidden : .automatic, edges: .bottom)
        }
        .shadowListStyle(.plain)
        .scrollDisabled(true)
      } else {
        VStack(spacing: 0) {
          ForEach(0..<rows, id: \.self) { index in
            gridRow
              .frame(minHeight: rowHeight)
              .background(ShadowTableMetrics.alternatesRows() && !index.isMultiple(of: 2) ? ShadowColor.surfaceWell : Color.clear)
          }
          Spacer(minLength: 0)
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label.map { Text($0) } ?? Text(verbatim: ""))
    .accessibilityHidden(label == nil)
  }

  private var gridRow: some View {
    GeometryReader { proxy in
      let gap = Spacing.space3
      let available = proxy.size.width - gap * CGFloat(columns.count + 1)
      let total = columns.reduce(0, +)
      HStack(spacing: gap) {
        ForEach(Array(columns.enumerated()), id: \.offset) { _, fraction in
          ShadowSkeletonLine().frame(width: max(0, available * fraction / total))
        }
      }
      .padding(.horizontal, gap)
      .frame(maxHeight: .infinity)
    }
  }
}

private struct ShadowTableSkeletonListRow: View {
  var body: some View {
    ShadowListRow(
      title: Text(verbatim: String(repeating: "0", count: 14)),
      subtitle: Text(verbatim: String(repeating: "0", count: 22)),
      trailing: ShadowBadge(LocalizedStringKey(String(repeating: "0", count: 9)), systemImage: "circle")
        .hidden()
        .overlay { Capsule().fill(ShadowColor.fillTrack) }
    )
    .redacted(reason: .placeholder)
  }
}

private struct ShadowTableBackdrop: ViewModifier {
  let isEmpty: Bool

  func body(content: Content) -> some View {
    #if os(macOS)
      content.alternatingRowBackgrounds(isEmpty ? .disabled : .enabled)
    #else
      content
    #endif
  }
}
