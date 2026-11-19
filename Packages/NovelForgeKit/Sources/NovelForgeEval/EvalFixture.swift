import Foundation
import NovelForgeCore
import ShadowStore

enum EvalFixture {
  static let novel = UUID(uuidString: "6f0c4d1e-0000-4000-8000-000000000e01") ?? UUID()
  static let wordTarget = WordTarget(min: 20, max: 400)

  static func seed(in store: VaultStore) async throws(EvalError) {
    let novel = novel
    do {
      try await store.write { transaction in
        _ = try NovelRecord(id: novel, name: "The Lighthouse", wordTarget: wordTarget).create(in: &transaction)
        _ = try EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara").create(in: &transaction)
        _ = try ThreadRecord(novel: novel, thread: "lamp", summary: "What the lamp shows", openedChapter: 1, status: ThreadProgress(state: .known(.open))).create(in: &transaction)
      }
    } catch {
      throw .setup("The fixture could not be seeded: \(error.code)")
    }
  }
}
