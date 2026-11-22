import SwiftUI

enum HeroRoute: Hashable {
  case comingBack
}

struct HeroRouteView: View {
  let route: HeroRoute
  let context: MemoirScreenContext

  var body: some View {
    switch route {
    case .comingBack: ComingBackView(context: context)
    }
  }
}
