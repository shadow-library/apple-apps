import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct NotebookView: View {
  let context: NovelContext
  @State private var model: NotebookModel

  init(context: NovelContext) {
    self.init(model: NotebookModel(context: context))
  }

  init(model: NotebookModel) {
    context = model.context
    _model = State(initialValue: model)
  }

  var body: some View {
    NotebookHome(model: model)
      .navigationDestination(for: NotebookRoute.self) { route in
        switch route {
        case .topic(let topic): NotebookTopicScreen(model: model, topic: topic).notebookSheets(model)
        case .entry(let id): NotebookEntryScreen(model: model, entry: id).notebookSheets(model)
        }
      }
      .notebookSheets(model)
      .task(id: model.generation) { await model.observe() }
  }
}

struct NotebookLoaded<Content: View>: View {
  let model: NotebookModel
  @ViewBuilder let content: (NotebookSnapshot) -> Content

  var body: some View {
    switch model.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error):
      ShadowContentUnavailable(Text("The Notebook could not be read", tableName: "Notebook"), kind: .error, message: error.text) {
        Button {
          model.retry()
        } label: {
          Text("Try Again", tableName: "Notebook")
        }
      }
      .fillingSurface()
    case .loaded(let snapshot):
      if snapshot.isAvailable {
        content(snapshot)
      } else {
        ShadowContentUnavailable(
          Text("The Notebook is unavailable", tableName: "Notebook"), kind: .error,
          message: Text("It is not up to date on this device yet. Try again after syncing.", tableName: "Notebook")
        )
        .fillingSurface()
      }
    }
  }
}

struct NotebookNotFound: View {
  var body: some View {
    ShadowContentUnavailable(
      Text("Entry not found", tableName: "Notebook"), systemImage: "note.text", message: Text("It may not have reached this device yet.", tableName: "Notebook")
    )
    .fillingSurface()
  }
}
