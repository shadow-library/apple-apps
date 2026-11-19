import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

/// apps/novel-forge-web/src/features/chapters/ChapterWorkspace.tsx:312-345,504-506: Summary for any chapter with prose, Amend for a final one.
struct ChapterTextActions: ViewModifier {
  let context: NovelContext
  let chapter: Int
  let body: ChapterContent.Body
  @Environment(JobRuntimes.self) private var runtimes
  @State private var summarizing = false
  @State private var amending = false

  func body(content: Content) -> some View {
    content
      .toolbar {
        ToolbarItemGroup {
          if hasProse {
            Button {
              summarizing = true
            } label: {
              Label(title: { Text("Summary…", tableName: "Amend") }, icon: { Image(systemName: "text.document") })
            }
            .shadowBarItem()
          }
          if final != nil {
            Button {
              amending = true
            } label: {
              Label(title: { Text("Amend…", tableName: "Amend") }, icon: { Image(systemName: "square.and.pencil") })
            }
            .shadowBarItem()
          }
        }
      }
      .sheet(isPresented: $summarizing) {
        SummarizeSheet(context: context, chapter: chapter, runtime: runtimes.existing(for: context.store), autoRun: false)
      }
      .sheet(isPresented: $amending) {
        if let final { AmendSheet(context: context, chapter: chapter, final: final) }
      }
  }

  private var final: ChapterContent.Final? {
    guard case .final(let final) = body else { return nil }
    return final
  }

  private var hasProse: Bool {
    switch body {
    case .final: true
    case .draft(let draft): !draft.editable.body.allSatisfy(\.isWhitespace)
    case .missing, .unreadable: false
    }
  }
}

extension View {
  func chapterTextActions(context: NovelContext, chapter: Int, body: ChapterContent.Body) -> some View {
    modifier(ChapterTextActions(context: context, chapter: chapter, body: body))
  }
}
