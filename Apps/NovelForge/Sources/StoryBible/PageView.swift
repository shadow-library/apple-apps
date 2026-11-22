import NovelForgeCore
import ShadowAppShell
import ShadowCore
import ShadowDesignSystem
import SwiftUI

struct PageView: View {
  enum Sheet: Identifiable {
    case edit(PageRecord, revision: String?)
    case versions(PageRecord, [PageVersion])

    var id: String {
      switch self {
      case .edit: "edit"
      case .versions: "versions"
      }
    }
  }

  let model: StoryBibleModel
  let address: PageAddress
  @State private var observer = ReadObserver<PageReading>()
  @State private var generation = 0
  @State private var sheet: Sheet?
  @State private var confirmingRemoval = false

  var body: some View {
    content
      .task(id: generation) {
        let store = model.context.store
        let input = PageReading.Input(novel: model.context.novel, address: address)
        await observer.run { store.observe(PageReading.self, input) }
      }
      .sheet(item: $sheet) { sheet in sheetContent(sheet) }
  }

  @ViewBuilder
  private var content: some View {
    switch observer.state {
    case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error): BibleReadFailed(error: error) { generation += 1 }
    case .loaded(let reading): loaded(reading)
    }
  }

  @ViewBuilder
  private func loaded(_ reading: PageReading) -> some View {
    switch reading.presence {
    case .missing: BibleNotFound(subject: .page, restore: nil)
    case .removed: BibleNotFound(subject: .page) { Task { await model.restorePage(address) } }
    case .unreadable: BibleUnreadable()
    case .live(let page): details(page, versions: reading.versions)
    }
  }

  private func details(_ page: PageRecord, versions: [PageVersion]) -> some View {
    let title = Pages.title(of: page)
    return ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        Text(verbatim: title).shadowFont(.largeTitle).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
        chips(page)
        bodyText(page.content.body ?? "")
      }
      .padding(Spacing.space6)
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .shadowScreen(.root)
    .navigationTitle(Text(verbatim: title))
    .toolbar {
      ToolbarItemGroup {
        Button {
          sheet = .edit(page, revision: versions.first(where: \.isHead)?.revision)
        } label: {
          Label(title: { Text("Edit", tableName: "StoryBible") }, icon: { Image(systemName: "pencil") })
        }
        .shadowBarItem()
        Button {
          sheet = .versions(page, versions)
        } label: {
          Label(title: { Text("Versions", tableName: "StoryBible") }, icon: { Image(systemName: "clock.arrow.circlepath") })
        }
        .shadowBarItem()
        Button(role: .destructive) {
          confirmingRemoval = true
        } label: {
          Label(title: { Text("Remove", tableName: "StoryBible") }, icon: { Image(systemName: "trash") })
        }
        .shadowBarItem()
      }
    }
    .confirmationDialog(Text("Remove this page?", tableName: "StoryBible"), isPresented: $confirmingRemoval, titleVisibility: .visible) {
      Button(role: .destructive) {
        Task { await model.removePage(address, title: title) }
      } label: {
        Text("Remove", tableName: "StoryBible")
      }
    } message: {
      Text("Its versions are kept, and you can restore it right after.", tableName: "StoryBible")
    }
  }

  private func chips(_ page: PageRecord) -> some View {
    HStack(spacing: Spacing.space2) {
      ShadowBadge(Text(page.section.label))
      if let summary = model.summary(of: address) {
        ShadowBadge(Text("\(summary.wordCount) words", tableName: "StoryBible"))
        PageAccessChips(page: summary)
      }
    }
  }

  @ViewBuilder
  private func bodyText(_ text: String) -> some View {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Text("This page has no text yet.", tableName: "StoryBible").shadowFont(.body).foregroundStyle(ShadowColor.textSecondary)
    } else {
      ProseView(markdown: text)
    }
  }

  @ViewBuilder
  private func sheetContent(_ sheet: Sheet) -> some View {
    switch sheet {
    case .edit(let page, let revision):
      PageFormSheet(
        mode: .edit(address: address, title: authoredTitle(page), body: page.content.body ?? "", revision: revision), derivedTitle: Pages.title(of: page), model: model
      ) { _ in }
    case .versions(let page, let versions):
      PageVersionsSheet(model: model, address: address, title: Pages.title(of: page), versions: versions)
    }
  }

  private func authoredTitle(_ page: PageRecord) -> String {
    page.content.frontmatter?["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}
