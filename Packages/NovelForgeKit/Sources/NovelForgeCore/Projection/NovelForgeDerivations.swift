public enum NovelForgeDerivations {
  public static let standard: [any Derivation] = Array(
    [
      ProjectionDerivations.all,
      StoryDerivations.all,
      NotebookDerivations.all,
      PlanWorldDerivations.all,
      ChapterDerivations.all,
      ChatDerivations.all,
    ].joined())
}
