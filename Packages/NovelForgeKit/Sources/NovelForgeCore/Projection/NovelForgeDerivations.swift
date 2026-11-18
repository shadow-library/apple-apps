public enum NovelForgeDerivations {
  public static let standard: [any Derivation] = Array(
    [
      ProjectionDerivations.all,
      StoryDerivations.all,
      NotebookDerivations.all,
      CanonDerivations.all,
      PlanWorldDerivations.all,
      ChapterDerivations.all,
      ChatDerivations.all,
      JobDerivations.all,
    ].joined())
}
