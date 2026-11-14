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
          VStack(alignment: .leading, spacing: Spacing.lg) {
            detail(for: selection)
          }
          .padding(Spacing.lg)
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
        HStack(spacing: Spacing.md) {
          Text(token.name).monospaced().frame(width: 48, alignment: .leading)
          RoundedRectangle(cornerRadius: CornerRadius.sm).fill(.tint).frame(width: token.value, height: Spacing.lg)
          Text("\(Int(token.value)) pt").foregroundStyle(.secondary)
        }
      }
    }
  }
}

enum SpacingToken: String, CaseIterable, Identifiable {
  case xxs, xs, sm, md, lg, xl, xxl

  var id: Self { self }
  var name: String { rawValue }

  var value: CGFloat {
    switch self {
    case .xxs: Spacing.xxs
    case .xs: Spacing.xs
    case .sm: Spacing.sm
    case .md: Spacing.md
    case .lg: Spacing.lg
    case .xl: Spacing.xl
    case .xxl: Spacing.xxl
    }
  }
}

#Preview {
  CatalogView()
}
