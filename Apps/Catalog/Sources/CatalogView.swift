import ShadowDesignSystem
import SwiftUI

struct CatalogView: View {
  @State private var selection: CatalogSection? = .buttons

  var body: some View {
    NavigationSplitView {
      List(CatalogSection.allCases, selection: $selection) { section in
        Label(section.title, systemImage: section.systemImage)
      }
      .navigationTitle("Catalog")
    } detail: {
      if let selection {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.space4) {
            detail(for: selection)
          }
          .padding(Spacing.space4)
        }
        .navigationTitle(selection.title)
      } else {
        ContentUnavailableView("Select a component", systemImage: "square.grid.2x2")
      }
    }
  }

  @ViewBuilder
  private func detail(for section: CatalogSection) -> some View {
    switch section {
    case .buttons:
      Button("Primary") {}.buttonStyle(.shadowPrimary)
      Button("Secondary") {}.buttonStyle(.shadowSecondary)
      Button("Destructive") {}.buttonStyle(.shadowDestructive)
      Button("Disabled") {}.buttonStyle(.shadowPrimary).disabled(true)
    case .cards:
      Text("Cards group related content on a material background.").shadowCard()
    case .spacing:
      ForEach(SpacingToken.allCases) { token in
        HStack(spacing: Spacing.space3) {
          Text(token.name).monospaced().frame(width: 80, alignment: .leading)
          RoundedRectangle(cornerRadius: Radius.md).fill(.tint).frame(width: token.value, height: Spacing.space4)
          Text("\(Int(token.value)) pt").foregroundStyle(.secondary)
        }
      }
    }
  }
}

enum SpacingToken: String, CaseIterable, Identifiable {
  case space05, space1, space2, space3, space4, space5, space6, space8, space10

  var id: Self { self }
  var name: String { rawValue }

  var value: CGFloat {
    switch self {
    case .space05: Spacing.space05
    case .space1: Spacing.space1
    case .space2: Spacing.space2
    case .space3: Spacing.space3
    case .space4: Spacing.space4
    case .space5: Spacing.space5
    case .space6: Spacing.space6
    case .space8: Spacing.space8
    case .space10: Spacing.space10
    }
  }
}

#Preview {
  CatalogView()
}
