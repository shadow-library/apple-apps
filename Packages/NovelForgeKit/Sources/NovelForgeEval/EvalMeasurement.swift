import Foundation
import NovelForgeCore
import ShadowStore

enum EvalMeasurement {
  static func report(store: VaultStore, novel: UUID, steps: [EvalStep], priorWindow: Int) async throws(EvalError) -> EvalReport {
    do throws(NovelEvaluationError) {
      let loaded = try await NovelEvaluation.chapters(novel: novel, in: store)
      let target: WordTarget?
      do throws(StoreError) {
        target = try await NovelEvaluation.wordTarget(novel: novel, in: store)
      } catch {
        throw .store(error)
      }
      return EvalReport(novel: novel, steps: steps, chapters: loaded.chapters, skipped: loaded.skipped, priorWindow: priorWindow, wordTarget: target)
    } catch {
      throw .setup("The chapters could not be read: \(error.code)")
    }
  }
}
