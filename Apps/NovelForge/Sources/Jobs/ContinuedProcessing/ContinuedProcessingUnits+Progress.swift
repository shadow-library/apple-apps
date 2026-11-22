import NovelForgeCore
import ShadowAppShell

extension ContinuedProcessingUnits {
  /// Output tokens received of those expected; the expected count shrinks as calls finish short of their cap, so it is held at no less than what arrived.
  func advanced(by progress: JobRunProgress) -> ContinuedProcessingUnits {
    let completed = max(completed, Int64(max(0, progress.tokensReceived)))
    return ContinuedProcessingUnits(completed: completed, total: max(Int64(progress.tokensExpected), completed, 1))
  }
}
