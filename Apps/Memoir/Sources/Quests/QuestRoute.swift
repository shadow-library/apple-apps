import Foundation
import SwiftUI

enum QuestRoute: Hashable {
  case detail(UUID)
}

struct QuestRouteView: View {
  let route: QuestRoute
  let context: MemoirScreenContext

  var body: some View {
    switch route {
    case .detail: MemoirPlaceholder(.quests)
    }
  }
}
