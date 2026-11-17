import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct BibleRow: View {
  let entry: BibleEntry

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.space3) {
      Image(systemName: systemImage).foregroundStyle(ShadowColor.textSecondary).frame(width: 20).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Spacing.space05) {
        Text(verbatim: entry.name).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).lineLimit(2)
        if !entry.summary.isEmpty {
          Text(verbatim: entry.summary).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).lineLimit(2)
        }
        HStack(spacing: Spacing.space2) {
          meta.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
          if case .page(let page) = entry.content { PageAccessChips(page: page) }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var systemImage: String {
    switch entry.content {
    case .page: "doc.text"
    case .entity(let entity): entity.type.knownType?.systemImage ?? "questionmark.square"
    }
  }

  @ViewBuilder
  private var meta: some View {
    switch entry.content {
    case .page(let page):
      HStack(spacing: Spacing.space1) {
        Text(page.section.label)
        Text(verbatim: "·")
        Text("\(page.wordCount) words", tableName: "StoryBible")
      }
    case .entity(let entity): entityMeta(entity)
    }
  }

  @ViewBuilder
  private func entityMeta(_ entity: EntityRecord) -> some View {
    HStack(spacing: Spacing.space1) {
      switch entity.type {
      case .known(let type): Text(type.label)
      case .unknown(let raw): Text(verbatim: raw)
      }
      if let significance = entity.significance?.knownSignificance {
        Text(verbatim: "·")
        Text(significance.label)
      }
    }
  }
}

struct PageAccessChips: View {
  let page: PageSummary

  var body: some View {
    if page.plannerOnly {
      ShadowBadge(Text("Planner only", tableName: "StoryBible"), intent: .warning)
    } else if page.writerExcluded {
      ShadowBadge(Text("Hidden from the writer", tableName: "StoryBible"), intent: .warning)
    }
  }
}
