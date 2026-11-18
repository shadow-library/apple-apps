public enum CanonDerivations {
  public static let all: [any Derivation] = [
    CanonBindingDerivation(),
    CanonAppearanceDerivation(),
    CharacterStateDerivation(),
    CanonRelationshipDerivation(),
    CharacterEventDerivation(),
    PromiseStateDerivation(),
  ]
}
