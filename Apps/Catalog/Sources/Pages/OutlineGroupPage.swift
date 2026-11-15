import ShadowDesignSystem
import SwiftUI

private typealias Node = ShadowTreeNode<String>

private let storyBible: [Node] = [
  Node(
    id: "characters", title: "Characters", systemImage: "folder",
    children: [
      Node(
        id: "archivist", title: "The Archivist", systemImage: "folder",
        children: [Node(id: "secret", title: "Secret: true name", systemImage: "doc.text", accessorySystemImage: "lock")]),
      Node(id: "mira", title: "Mira Vale", systemImage: "folder", children: [Node(id: "mira-bio", title: "Early years", systemImage: "doc.text")]),
    ]),
  Node(id: "places", title: "Places", systemImage: "folder", children: (1...7).map { Node(id: "place-\($0)", title: "Location \($0)", systemImage: "doc.text") }),
  Node(id: "timeline", title: "Secret timeline", systemImage: "doc.text", accessorySystemImage: "lock"),
]

private let longTree: [Node] = [
  Node(
    id: "long", title: "The long and winding index of everything the Archivist remembered about the lantern court", systemImage: "folder",
    children: [
      Node(id: "long-leaf", title: "A very long page title that keeps going until it has to wrap onto a second line", systemImage: "doc.text", accessorySystemImage: "lock")
    ])
]

struct OutlineGroupPage: View {
  @State private var selection: String? = "secret"
  @State private var expanded: Set<String> = ["characters", "archivist"]

  var body: some View {
    List(selection: $selection) {
      StateListSection(
        "Story bible",
        note:
          "Nested disclosure groups with the system chevron and a 22pt indent, expanded by state so Characters and The Archivist start open. Folders show a count, locked pages a lock. On iPhone prefer drilling down."
      ) {
        ForEach(storyBible) { node in
          OutlineTreeRow(node: node, expanded: $expanded, selection: selection)
        }
      }
      StateListSection("Long text", note: "A collapsed `OutlineGroup`. Titles wrap to two lines; the count stays trailing.") {
        OutlineGroup(longTree, children: \.children) { node in
          OutlineRow(node: node, isSelected: selection == node.id).tag(node.id)
        }
        #if !os(macOS)
          .shadowListRowChrome()
        #endif
      }
      CatalogListEnd()
    }
    .shadowListStyle()
    .catalogListPage(.outlineGroup, anchors: ["Story bible", "Long text"])
  }
}

private struct OutlineTreeRow: View {
  let node: Node
  @Binding var expanded: Set<String>
  let selection: String?

  var body: some View {
    if let children = node.children, !children.isEmpty {
      DisclosureGroup(isExpanded: isExpanded) {
        ForEach(children) { child in
          OutlineTreeRow(node: child, expanded: $expanded, selection: selection)
        }
      } label: {
        OutlineRow(node: node, isSelected: selection == node.id).tag(node.id)
      }
      #if !os(macOS)
        .shadowListRowChrome()
      #endif
    } else {
      OutlineRow(node: node, isSelected: selection == node.id).tag(node.id)
    }
  }

  private var isExpanded: Binding<Bool> {
    Binding(
      get: { expanded.contains(node.id) },
      set: { isOpen in
        if isOpen { expanded.insert(node.id) } else { expanded.remove(node.id) }
      })
  }
}

private struct OutlineRow: View {
  let node: Node
  let isSelected: Bool

  private var isRoot: Bool { storyBible.contains { $0.id == node.id } || longTree.contains { $0.id == node.id } }

  var body: some View {
    ShadowListRow(
      title: Text(verbatim: node.title),
      isSelected: isSelected,
      isEmphasized: isRoot,
      leading: { leadingSymbol },
      trailing: { trailing }
    )
  }

  @ViewBuilder
  private var leadingSymbol: some View {
    if node.isLeaf {
      Image(systemName: node.systemImage)
        .foregroundStyle(ShadowColor.accentText)
        .frame(width: ShadowListMetrics().tileSize, height: ShadowListMetrics().tileSize)
    } else {
      ShadowSymbolTile(systemImage: node.systemImage, tint: .neutral)
    }
  }

  @ViewBuilder
  private var trailing: some View {
    if let accessory = node.accessorySystemImage {
      Image(systemName: accessory).foregroundStyle(ShadowColor.textTertiary)
    } else if node.descendantCount > 0 {
      Text(node.descendantCount, format: .number).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
    }
  }
}
