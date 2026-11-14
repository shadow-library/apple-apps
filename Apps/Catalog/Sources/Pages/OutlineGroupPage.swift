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

  var body: some View {
    List(selection: $selection) {
      StateListSection(
        "Story bible",
        note:
          "Native `OutlineGroup` rows with the system disclosure chevron. Folders show their descendant count and locked pages a lock. Selection uses the list’s selected style, and Mac supports ← and → to collapse and expand. On iPhone prefer drilling down with navigation, and keep disclosure to one extra level."
      ) {
        OutlineGroup(storyBible, children: \.children) { node in
          OutlineRow(node: node, isSelected: selection == node.id).tag(node.id)
        }
      }
      StateListSection("Long text", note: "Titles wrap to two lines; the count stays trailing.") {
        OutlineGroup(longTree, children: \.children) { node in
          OutlineRow(node: node, isSelected: selection == node.id).tag(node.id)
        }
      }
    }
    .shadowListStyle()
    .catalogListPage(.outlineGroup, anchors: ["Story bible", "Long text"])
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
      Image(systemName: node.systemImage).foregroundStyle(ShadowColor.accentText)
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
