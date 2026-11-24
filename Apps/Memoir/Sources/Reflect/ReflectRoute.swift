import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

enum ReflectRoute: Hashable {
  case record(String)
}

struct ReflectRouteView: View {
  let route: ReflectRoute
  let context: MemoirScreenContext

  var body: some View {
    switch route {
    case .record(let id): HistoryRecordView(context: context, id: id)
    }
  }
}

/// A history record pushed on a narrow screen; it says so when the record has gone, as when another device deleted it.
struct HistoryRecordView: View {
  @State private var model: HistoryRecordModel
  @Environment(MemoirModules.self) private var modules: MemoirModules?

  init(context: MemoirScreenContext, id: String, bodyClasses: Set<SyncClass> = ReflectBody.onThisDevice) {
    _model = State(initialValue: HistoryRecordModel(context: context, id: id, bodyClasses: bodyClasses))
  }

  var body: some View {
    ScrollView {
      Group {
        if let failure = model.day.failure {
          ShadowContentUnavailable(Text("Couldn’t load this right now", tableName: "Reflect"), kind: .error, message: failure.text)
        } else {
          switch model.presentation {
          case .loading:
            ProgressView().frame(maxWidth: .infinity)
          case .failed(let error):
            ShadowContentUnavailable(Text("Couldn’t load this right now", tableName: "Reflect"), kind: .error, message: error.text)
          case .missing:
            ShadowContentUnavailable(
              Text("This record is no longer in your history", tableName: "Reflect"),
              message: Text("It was removed, perhaps on another device.", tableName: "Reflect"))
          case .found(let presentation):
            HistoryRecordDetail(presentation: presentation, today: model.day.day?.today).shadowCard()
          }
        }
      }
      .padding(Spacing.space4)
      .frame(maxWidth: ShadowMetrics.readableWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(ShadowColor.surfaceApp)
    .navigationTitle(Text("Record", tableName: "Reflect"))
    .shadowScreen(.pushed)
    .task { await model.followToday() }
    .task { await model.observeLookups() }
    .task(id: PageRead(today: model.day.day?.today, modules: modules?.selection ?? .all)) {
      model.apply(modules?.selection ?? .all)
      await model.observe()
    }
  }
}

extension HistoryRecordView {
  fileprivate struct PageRead: Hashable {
    let today: LocalDate?
    let modules: ModuleSelection
  }
}
