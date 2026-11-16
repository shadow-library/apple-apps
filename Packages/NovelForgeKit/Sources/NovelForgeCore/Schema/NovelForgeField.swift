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
