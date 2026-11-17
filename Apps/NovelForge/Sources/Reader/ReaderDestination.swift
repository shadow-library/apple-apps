import SwiftUI

struct ReaderDestination: View {
  let route: ReaderRoute
  let context: NovelContext
  let model: ReaderModel

  var body: some View {
    switch route {
    case .chapter(let chapter): ChapterView(context: context, chapter: chapter).environment(model)
    case .versions(let chapter): VersionsView(context: context, chapter: chapter).environment(model)
    }
  }
}
