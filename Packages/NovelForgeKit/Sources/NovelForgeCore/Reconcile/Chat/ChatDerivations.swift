public enum ChatDerivations {
  public static let all: [any Derivation] = [
    ChatMessageRowDerivation(),
    ChatSummaryRowDerivation(),
    ChatSessionStateDerivation(),
    ChatTranscriptDerivation(),
    ProposalChangeRowDerivation(),
    ProposalChangeEntryDerivation(),
    ProposalStateDerivation(),
  ]
}
