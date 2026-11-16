public enum NovelForgeDerivations {
  public static let standard: [any Derivation] = Array(
    [
      ProjectionDerivations.all,
      ChapterDerivations.all,
      StoryDerivations.all,
      NotebookDerivations.all,
    ].joined())
}
