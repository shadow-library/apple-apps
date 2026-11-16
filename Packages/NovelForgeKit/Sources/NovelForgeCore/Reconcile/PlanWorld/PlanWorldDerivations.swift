public enum PlanWorldDerivations {
  public static let all: [any Derivation] = [
    ChapterContractDerivation(),
    PlanWorldDerivation(),
    PlanRevealDerivation(),
    MilestoneClaimDerivation(),
    MilestoneStateDerivation(),
  ]
}
