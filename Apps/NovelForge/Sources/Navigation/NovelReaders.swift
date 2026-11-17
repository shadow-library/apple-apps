import Foundation

@MainActor
final class NovelReaders {
  private var models: [UUID: ReaderModel] = [:]

  func model(for context: NovelContext) -> ReaderModel {
    if let existing = models[context.novel] { return existing }
    let created = ReaderModel(context: context)
    models[context.novel] = created
    return created
  }

  func prune(keeping novels: Set<UUID>) {
    models = models.filter { novels.contains($0.key) || $0.value.hasUnsavedWork }
  }
}
