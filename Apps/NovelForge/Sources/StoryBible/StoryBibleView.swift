import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct StoryBibleView: View {
  let context: NovelContext
  @State private var model: StoryBibleModel
  @State private var removing: BibleEntry?
  @Environment(NovelNavigator.self) private var navigator: NovelNavigator?

  init(context: NovelContext) {
    self.context = context
    _model = State(initialValue: StoryBibleModel(context: context))
  }

  var body: some View {
    @Bindable var model = model
    content
      .navigationTitle(Text(NovelSection.storyBible.title))
      .navigationDestination(for: StoryBibleRoute.self) { destination($0) }
      .searchable(text: $model.query, prompt: Text("Search the Story Bible", tableName: "StoryBible"))
      .toolbar { toolbar }
      .task(id: model.generation) { await model.observe() }
      .sheet(item: $model.presenting) { sheet in sheetContent(sheet) }
      .confirmationDialog(
        Text("Remove this entry?", tableName: "StoryBible"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible,
        presenting: removing
      ) { entry in
        Button(role: .destructive) {
          Task { await remove(entry) }
        } label: {
          Text("Remove", tableName: "StoryBible")
        }
      } message: { entry in
        Text("“\(entry.name)” can be restored right after.", tableName: "StoryBible")
      }
      .alert(
        Text("Something went wrong", tableName: "StoryBible"), isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
        presenting: model.failure
      ) { _ in
        Button {
          model.failure = nil
        } label: {
          Text("OK", tableName: "StoryBible")
        }
      } message: { failure in
        failure.error.text
      }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem {
      Menu {
        Button {
          model.present(.newPage)
        } label: {
          Label(title: { Text("New Page…", tableName: "StoryBible") }, icon: { Image(systemName: "doc.badge.plus") })
        }
        Button {
          model.present(.newEntity)
        } label: {
          Label(title: { Text("New Entity…", tableName: "StoryBible") }, icon: { Image(systemName: "person.badge.plus") })
        }
      } label: {
        Label(title: { Text("New", tableName: "StoryBible") }, icon: { Image(systemName: "plus") })
      }
      .shadowBarItem()
    }
    ToolbarItem {
      Picker(selection: $model.kind) {
        ForEach(BibleKindFilter.allCases) { kind in Text(kind.label).tag(kind) }
      } label: {
        Text("Show", tableName: "StoryBible")
      }
      .pickerStyle(.menu)
      .shadowBarItem()
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error): BibleReadFailed(error: error, retry: model.retry)
    case .loaded(let contents): loaded(contents)
    }
  }

  @ViewBuilder
  private func loaded(_ contents: StoryBibleContents) -> some View {
    if contents.pages.isUnavailable && contents.entities.isUnavailable {
      ShadowContentUnavailable(
        Text("The Story Bible is unavailable", tableName: "StoryBible"), systemImage: "exclamationmark.triangle",
        message: Text("It is not up to date on this device yet. Try again in a moment.", tableName: "StoryBible")
      ) {
        Button(action: model.retry) { Text("Try Again", tableName: "StoryBible") }
      }
      .fillingSurface()
    } else {
      list(contents)
    }
  }

  private func list(_ contents: StoryBibleContents) -> some View {
    let catalogue = model.catalogue
    let groups = catalogue.groups(kind: model.kind, query: model.query)
    let emptyPages = catalogue.matchingEmptyPages(kind: model.kind, query: model.query)
    let removed = model.removedEntries(kind: model.kind, query: model.query)
    return List {
      if contents.pages.isUnavailable { Section { unavailableNote(Text("Pages are not up to date on this device.", tableName: "StoryBible")) } }
      if contents.entities.isUnavailable { Section { unavailableNote(Text("Entities are not up to date on this device.", tableName: "StoryBible")) } }
      ForEach(groups) { group in
        Section {
          ForEach(group.subgroups) { subgroup in
            Text(subgroup.label).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).accessibilityAddTraits(.isHeader)
            ForEach(subgroup.entries) { entry in row(entry) }
          }
        } header: {
          ShadowSidebarHeader(Text(group.topic.label))
        }
      }
      if !emptyPages.isEmpty {
        Section {
          ForEach(emptyPages, id: \.slug) { page in emptyPageRow(page) }
        } header: {
          ShadowSidebarHeader(Text("Empty pages", tableName: "StoryBible"))
        }
      }
      unreadableNote(contents)
      removedSection(removed)
    }
    .overlay { emptyOverlay(catalogue, groups: groups, emptyPages: emptyPages, removed: removed) }
  }

  @ViewBuilder
  private func emptyOverlay(_ catalogue: BibleCatalogue, groups: [BibleGroup], emptyPages: [PageSummary], removed: [RemovedEntry]) -> some View {
    if catalogue.isEmpty && model.removed.isEmpty && model.state.value?.pages.isUnavailable == false && model.state.value?.entities.isUnavailable == false {
      ShadowContentUnavailable(
        Text("The Story Bible is empty", tableName: "StoryBible"), systemImage: "books.vertical",
        message: Text("Add pages and entries for your world, cast and rules.", tableName: "StoryBible")
      ) {
        Button {
          model.present(.newPage)
        } label: {
          Text("New Page…", tableName: "StoryBible")
        }
        Button {
          model.present(.newEntity)
        } label: {
          Text("New Entity…", tableName: "StoryBible")
        }
      }
    } else if !(catalogue.isEmpty && model.removed.isEmpty) && groups.isEmpty && emptyPages.isEmpty && removed.isEmpty {
      ShadowContentUnavailable(
        Text("Nothing matches", tableName: "StoryBible"), systemImage: "magnifyingglass", message: Text("Try another search or show all kinds.", tableName: "StoryBible"))
    }
  }

  private func row(_ entry: BibleEntry) -> some View {
    NavigationLink(value: entry.route) { BibleRow(entry: entry) }
      .contextMenu {
        Button(role: .destructive) {
          removing = entry
        } label: {
          Label(title: { Text("Remove…", tableName: "StoryBible") }, icon: { Image(systemName: "trash") })
        }
      }
  }

  private func emptyPageRow(_ page: PageSummary) -> some View {
    let address = PageAddress(section: page.section, slug: page.slug)
    return NavigationLink(value: StoryBibleRoute.page(address)) {
      VStack(alignment: .leading, spacing: Spacing.space05) {
        Text(verbatim: page.title).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
        Text(page.section.label).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
    .contextMenu {
      Button(role: .destructive) {
        Task { await model.removePage(address, title: page.title) }
      } label: {
        Label(title: { Text("Remove", tableName: "StoryBible") }, icon: { Image(systemName: "trash") })
      }
    }
  }

  @ViewBuilder
  private func removedSection(_ removed: [RemovedEntry]) -> some View {
    if !removed.isEmpty {
      Section {
        ForEach(removed) { entry in
          ShadowListRow(
            title: Text(verbatim: entry.name), caption: Text("Removed", tableName: "StoryBible"),
            leading: { Image(systemName: "trash").foregroundStyle(ShadowColor.textTertiary) },
            trailing: {
              Button {
                Task { await model.restore(entry) }
              } label: {
                Text("Restore", tableName: "StoryBible")
              }
            })
        }
      } header: {
        ShadowSidebarHeader(Text("Recently removed", tableName: "StoryBible"))
      }
    }
  }

  private func unavailableNote(_ message: Text) -> some View {
    Label(title: { message }, icon: { Image(systemName: "exclamationmark.triangle") }).shadowFont(.footnote).foregroundStyle(ShadowColor.warningText)
  }

  @ViewBuilder
  private func unreadableNote(_ contents: StoryBibleContents) -> some View {
    let unreadable = (contents.pages.value?.unreadable ?? 0) + (contents.entities.value?.unreadable ?? 0)
    if unreadable > 0 {
      Section {
        unavailableNote(Text("\(unreadable) records cannot be read by this version", tableName: "StoryBible"))
      }
    }
  }

  @ViewBuilder
  private func destination(_ route: StoryBibleRoute) -> some View {
    switch route {
    case .page(let address): PageView(model: model, address: address)
    case .entity(let key): EntityView(model: model, key: key)
    }
  }

  @ViewBuilder
  private func sheetContent(_ sheet: BibleSheet) -> some View {
    switch sheet {
    case .newPage: PageFormSheet(mode: .create, model: model) { navigator?.push(StoryBibleRoute.page($0)) }
    case .newEntity: EntityFormSheet(mode: .create(type: .character), model: model) { navigator?.push(StoryBibleRoute.entity($0)) }
    }
  }

  private func remove(_ entry: BibleEntry) async {
    switch entry.content {
    case .page(let page): await model.removePage(PageAddress(section: page.section, slug: page.slug), title: page.title)
    case .entity(let entity): await model.removeEntity(entity.entity, name: entity.name)
    }
  }
}
