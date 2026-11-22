import Foundation
import MemoirCore
import SwiftUI

enum QuestRoute: Hashable {
  case detail(UUID)
}

struct QuestRouteView: View {
  let route: QuestRoute
  let stores: MemoirStores

  var body: some View {
    switch route {
    case .detail: MemoirPlaceholder(.quests)
    }
  }
}
