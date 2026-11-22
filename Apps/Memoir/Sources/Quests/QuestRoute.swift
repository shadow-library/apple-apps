import Foundation
import SwiftUI

enum QuestRoute: Hashable {
  case detail(UUID)
  case new
  case edit(UUID)
  case duplicate(UUID)
}

struct QuestRouteView: View {
  let route: QuestRoute
  let context: MemoirScreenContext

  var body: some View {
    switch route {
    case .detail(let id): QuestDetailView(questID: id, context: context)
    case .new: QuestBuilderView(mode: .create, context: context)
    case .edit(let id): QuestBuilderView(mode: .edit(id), context: context)
    case .duplicate(let id): QuestBuilderView(mode: .duplicate(id), context: context)
    }
  }
}
