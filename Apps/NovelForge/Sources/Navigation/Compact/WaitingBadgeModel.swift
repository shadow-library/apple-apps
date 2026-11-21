import NovelForgeCore
import Observation
import ShadowStore

@MainActor
@Observable
final class WaitingBadgeModel {
  private let observer = ReadObserver<Int>()

  var count: Int { observer.state.value ?? 0 }

  func observe(_ context: NovelContext) async {
    let (store, novel) = (context.store, context.novel)
    await observer.run { store.observeReads { transaction in try ChatWaitingOnYou.load(novel, in: transaction).contents.value?.pendingCount ?? 0 } }
  }
}
