public enum NovelForgeDerivations {
  public static let standard: [any Derivation] = Array(
    [
      ProjectionDerivations.all,
      StoryDerivations.all,
      NotebookDerivations.all,
      CanonDerivations.all,
      PlanWorldDerivations.all,
      JobDerivations.all,
      ChapterDerivations.all,
      ChatDerivations.all,
    ].joined())
}
