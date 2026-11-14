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
    Group {
      if isLoading {
        ShadowTableSkeleton(columns: skeletonColumns, isList: layout == .list, label: loadingLabel)
      } else {
        content
      }
    }
    .environment(\.defaultMinListRowHeight, ShadowMetrics.rowHeight)
    .environment(\.shadowMaterialLayer, .content)
    .background(ShadowColor.surfaceCard)
    .overlay {
      if rows.isEmpty && !isLoading { empty }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch layout {
    case .grid:
      Table(rows, selection: selection, sortOrder: sortOrder) { columns }
        .tableStyle(.inset)
        .modifier(ShadowTableBackdrop(isEmpty: rows.isEmpty))
        .scrollContentBackground(.hidden)
    case .list:
      List(rows, selection: selection) { row in compact(row) }
        .shadowListStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
        .safeAreaInset(edge: .top, spacing: 0) {
          if let compactSort { ShadowTableSortMenu(sort: compactSort, sortOrder: sortOrder) }
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
    VStack(spacing: 0) {
      ForEach(0..<rows, id: \.self) { index in
        row
          .frame(minHeight: rowHeight)
          .background(index.isMultiple(of: 2) || isList ? Color.clear : ShadowColor.surfaceWell)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label.map { Text($0) } ?? Text(verbatim: ""))
    .accessibilityHidden(label == nil)
  }

  @ViewBuilder
  private var row: some View {
    if isList {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        ShadowSkeletonLine(.title, widthFraction: 0.5)
        ShadowSkeletonLine(widthFraction: 0.3)
      }
      .padding(.vertical, Spacing.space2)
      .padding(.horizontal, ShadowListMetrics().horizontalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
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
