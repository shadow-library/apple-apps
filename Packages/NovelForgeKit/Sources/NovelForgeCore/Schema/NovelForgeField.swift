enum CommonField: String, CaseIterable {
  case naturalKey = "natural_key"
  // Only create and restore write false, and they write every field; an edit never writes it; a removal writes true.
  case removed
}

public enum NovelField: String, CaseIterable {
  case name
  case title
  case contentMode = "content_mode"
  case costTier = "cost_tier"
  case wordTarget = "word_target"
  case brief
  case premise
  case themes
  case theme
  case endingQuestion = "ending_question"
  case ending
  case readerPromise = "reader_promise"
  case protagonist
  case opposition
  case writingStyle = "writing_style"
  case archived
}

public enum VolumeField: String, CaseIterable {
  case ordinal
  case title
  case objective
  case body
  case goalMet = "goal_met"
}

public enum MilestoneField: String, CaseIterable {
  case label
  case subject
  case kind
}

public enum ThreadField: String, CaseIterable {
  case summary
  case openedChapter = "opened_chapter"
  // Only the author's own operations write it; what a pipeline observes about a promise gets its own records (apps/novel-forge-server/src/modules/ai/graphs/apply-continuity.ts:137-146 does not hold across devices).
  case status
  case payoffWindow = "payoff_window"
  case payoffMilestone = "payoff_milestone"
  case payoffVolume = "payoff_volume"
  case dormant
}

public enum MysteryField: String, CaseIterable {
  case question
  case openedChapter = "opened_chapter"
  // Only the author's own operations write it; what a pipeline observes about a promise gets its own records (apps/novel-forge-server/src/modules/ai/graphs/apply-continuity.ts:137-146 does not hold across devices).
  case status
  case truthFact = "truth_fact"
  case payoffWindow = "payoff_window"
  case payoffMilestone = "payoff_milestone"
  case payoffVolume = "payoff_volume"
  case dormant
}

public enum SecretField: String, CaseIterable {
  case text
  case subjects
  case constraintNote = "constraint_note"
  case writerNote = "writer_note"
  case cluesAndTerms = "clues_and_terms"
  case revealChapter = "reveal_chapter"
  case unlock
  case source
}

public enum EntityField: String, CaseIterable {
  case type
  case name
  case attributes
  case significance
  case status
  case origin
  case notes
  case motivation
  case body
  case appearance
  case wikiVisibility = "wiki_visibility"
}

public enum CharacterKnowledgeField: String, CaseIterable {
  case reveal
}

public enum FinalChapterField: String, CaseIterable, Sendable {
  case canon
  case summary
}

public enum DraftMark: String, CaseIterable, Sendable {
  case approved
}

public enum ChapterPlanMark: String, CaseIterable, Sendable {
  case finalized
}

// apps/novel-forge-server/src/database/schemas/projects.ts:90 sets min and max together
enum WordTargetMember: String, CaseIterable {
  case min
  case max
}

// apps/novel-forge-server/src/modules/refinement/apply/promise.handler.ts:137 stamps the paid-off chapter with the status
enum PromiseStatusMember: String, CaseIterable {
  case state
  case chapter
}

// apps/novel-forge-server/src/common/reveal-term.ts:39 judges the clues against the terms
enum CluesAndTermsMember: String, CaseIterable {
  case clues
  case terms
}

// apps/novel-forge-server/src/modules/bible/fact/fact.service.ts:128 writes these together; common/provisional-knowledge.ts:44 never overrides a manual reveal
enum ManualRevealMember: String, CaseIterable {
  case chapter
  case note
}

// Written in one set when the chapter is committed, so what was bound and what was produced always come from one device.
enum FinalChapterCanonMember: String, CaseIterable {
  case draftRevision = "draft_revision"
  case planRevision = "plan_revision"
  case approval
  case title
  case body
  case summary
  case note
  case generator
  case isolated
  case volume
  case contract
  // The secret keys this chapter disclosed to readers, frozen at finalize; null when not recorded.
  case disclosed
}

// The finalized plan revision's apps/novel-forge-server/src/common/knowledge-contract.ts:7 contract, database/schemas/generation.ts:120 claimed milestones and :121 ending flag.
enum CanonContractMember: String, CaseIterable {
  case pov
  case learns
  case claimedMilestones = "claimed_milestones"
  case isEnding = "is_ending"
}

enum CanonLearnMember: String, CaseIterable {
  case entity
  case fact
}

public enum ApprovalMember: String, CaseIterable, Sendable {
  case novel
  case chapter
  case kind
  case draftRevision = "draft_revision"
  case planRevision = "plan_revision"
  case planTermsDigest = "plan_terms_digest"
  case upstreamDigest = "upstream_digest"
}

public enum ApprovalKind: String, CaseIterable, Sendable {
  case standard
  case asWritten = "as_written"
}

public enum NotebookEntryMember: String, CaseIterable, Sendable {
  case novel
  case kind
  case topic
  case statement
  case why
  case rejectedAlternatives = "rejected_alternatives"
  case writerLine = "writer_line"
  case decidedBy = "decided_by"
  case stepKey = "step_key"
  case payload
  // Links added after an entry exists need their own appended kind: apps/novel-forge-server/src/modules/ledger/ledger.service.ts:161 grows them in place.
  case links
  case supersedes
  case idea
  case rejectionScope = "rejection_scope"
  case rejectionAnchor = "rejection_anchor"
}

public enum NotebookWithdrawalMember: String, CaseIterable, Sendable {
  case novel
  case entry
  case reason
}

// apps/novel-forge-server/src/database/schemas/refinement.ts:157-187
public enum ChatSessionField: String, CaseIterable, Sendable {
  case novel
  case title
  // apps/novel-forge-server/src/modules/refinement/chat-session.service.ts:164 titles only a session still untitled, so a generated title never replaces the author's.
  case autoTitle = "auto_title"
  case mode
  case status
}

// apps/novel-forge-server/src/database/schemas/refinement.ts:153
public enum ChatSessionMode: String, CaseIterable, Sendable {
  case manual
  case auto
}

// apps/novel-forge-server/src/database/schemas/refinement.ts:151; deleting is `removed`, which an archive never writes.
public enum ChatSessionStatus: String, CaseIterable, Sendable {
  case active
  case archived
}

// apps/novel-forge-server/src/database/schemas/refinement.ts:152
public enum ChatRole: String, CaseIterable, Sendable {
  case user
  case assistant
}

// apps/novel-forge-server/src/database/schemas/refinement.ts:189-226, plus the turn's choices that modules/refinement/chat.dto.ts:486-511 never stores.
public enum ChatMessageMember: String, CaseIterable, Sendable {
  case novel
  case session
  case role
  case content
  case contexts
  // The reply whose question card this message answers.
  case answers
  // The newest message of the session the writing device held; it replaces the reference's ordinal (refinement.ts:199).
  case seen
  case pace
  case deeper
  case contentMode = "content_mode"
  case justDiscussing = "just_discussing"
  case proseEdits = "prose_edits"
  case tokens
  case question
  case trace
  case modelCalls = "model_calls"
  case appliedProposal = "applied_proposal"
  case cardProposal = "card_proposal"
  case applyNote = "apply_note"
  case held
}

// apps/novel-forge-server/src/modules/refinement/chat-compaction.service.ts:142 and :168
public enum ChatSummaryMember: String, CaseIterable, Sendable {
  case novel
  case session
  case covered
  case text
  case contentMode = "content_mode"
}

public enum ProposalField: String, CaseIterable, Sendable {
  case card
  case decision
  case applied
}

// apps/novel-forge-server/src/database/schemas/refinement.ts:155, ranked so concurrent decisions settle on the one with the most consequence.
public enum ProposalDecision: String, CaseIterable, Sendable {
  case pending
  case superseded
  case discarded
  case applied
}

// Written in one set when the proposal is staged: apps/novel-forge-server/src/modules/refinement/proposal.service.ts:160-175.
public enum ProposalCardMember: String, CaseIterable, Sendable {
  case novel
  case session
  case message
  case kind
  case summary
  case changeSet = "change_set"
  case baseline
  case warnings
  case diagnostics
  case supersedes
  case run
}

// Written in one set by the first apply: apps/novel-forge-server/src/database/schemas/refinement.ts:246 and :253, modules/refinement/apply/apply.types.ts:20.
public enum ProposalAppliedMember: String, CaseIterable, Sendable {
  case postState = "post_state"
  case sources
  case automatic
}

/// An apply writes a change record only for each index it selected; an index of an applied proposal with no record reads as declined, so concurrent applies
/// of different selections record the union of what was really applied. Undo, redo and revert are guarded by each change's own `undo`, never by the
/// proposal's `applied`, which is the first applier's provenance only.
public enum ProposalChangeField: String, CaseIterable, Sendable {
  case status
  case undo
  case undoneState = "undone_state"
  case result
}

// apps/novel-forge-server/src/modules/refinement/apply/apply.types.ts:18; `declined` is never stored, it is the absence of a record.
public enum ProposalChangeStatus: String, CaseIterable, Sendable {
  case applied
  case pending
  case failed
  case reverted
}

// apps/novel-forge-server/src/modules/refinement/op-undo.ts:5-8; the post state is the change's share of refinement.ts:253, so each change guards its own undo.
public enum ProposalChangeUndoMember: String, CaseIterable, Sendable {
  case inverse
  case priorState = "prior_state"
  case postState = "post_state"
}

// apps/novel-forge-server/src/modules/refinement/apply/apply.types.ts:21-24
public enum ProposalChangeResultMember: String, CaseIterable, Sendable {
  case error
  case note
  case result
}
