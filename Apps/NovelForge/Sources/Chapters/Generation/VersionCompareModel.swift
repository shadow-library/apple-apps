import Foundation
import Observation
import ShadowStore

@MainActor
@Observable
final class VersionCompareModel {
  enum State: Equatable {
    case loading
    case same
    case ready(VersionDiff)
    case unreadable
  }

  private(set) var state = State.loading
  private let store: VaultStore
  private let novel: UUID
  private let chapter: Int

  init(store: VaultStore, novel: UUID, chapter: Int) {
    self.store = store
    self.novel = novel
    self.chapter = chapter
  }

  func load(older: String, newer: String) async {
    guard older != newer else {
      state = .same
      return
    }
    state = .loading
    let (store, novel, chapter) = (store, novel, chapter)
    guard let texts = try? await store.versionTexts(novel: novel, chapter: chapter, older: older, newer: newer) else {
      state = .unreadable
      return
    }
    let diff = await Task.detached { VersionDiff.compare(from: texts.older, to: texts.newer) }.value
    guard !Task.isCancelled else { return }
    state = .ready(diff)
  }
}
