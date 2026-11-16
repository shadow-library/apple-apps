import Foundation
import ShadowCore

// apps/novel-forge-server/src/modules/ledger/ledger.types.ts:15
public struct NotebookIdeaRejection: Sendable, Equatable {
  public var ideaId: String
  public var scope: LedgerRejectionScope
  public var anchor: JSONValue?

  public init(ideaId: String, scope: LedgerRejectionScope, anchor: JSONValue? = nil) {
    self.ideaId = ideaId
    self.scope = scope
    self.anchor = anchor
  }
}

// ledger.types.ts:22
public struct NewNotebookEntry: Sendable, Equatable {
  public var kind: LedgerEntryKind
  public var topic: String
  public var statement: String
  public var why: String?
  public var rejectedAlternatives: [String]
  public var writerLine: String?
  public var decidedBy: LedgerDecidedBy
  public var stepKey: String?
  public var payload: JSONValue?
  public var links: NotebookLinks
  public var idea: NotebookIdeaRejection?

  public init(
    kind: LedgerEntryKind, topic: String, statement: String, why: String? = nil, rejectedAlternatives: [String] = [], writerLine: String? = nil,
    decidedBy: LedgerDecidedBy, stepKey: String? = nil, payload: JSONValue? = nil, links: NotebookLinks = NotebookLinks(), idea: NotebookIdeaRejection? = nil
  ) {
    self.kind = kind
    self.topic = topic
    self.statement = statement
    self.why = why
    self.rejectedAlternatives = rejectedAlternatives
    self.writerLine = writerLine
    self.decidedBy = decidedBy
    self.stepKey = stepKey
    self.payload = payload
    self.links = links
    self.idea = idea
  }
}

// ledger.types.ts:38 and ledger.dto.ts:63
public struct AuthorNotebookEntry: Sendable, Equatable {
  public var kind: LedgerEntryKind
  public var topic: String
  public var statement: String
  public var why: String?
  public var payload: [String: JSONValue]?

  public init(kind: LedgerEntryKind, topic: String, statement: String, why: String? = nil, payload: [String: JSONValue]? = nil) {
    self.kind = kind
    self.topic = topic
    self.statement = statement
    self.why = why
    self.payload = payload
  }
}

// ledger.types.ts:23 `SupersedingEntry`: a successor keeps the topic of the entry it replaces
public struct NotebookSuccessor: Sendable, Equatable {
  public var kind: LedgerEntryKind
  public var decidedBy: LedgerDecidedBy
  public var statement: String
  public var why: String?
  public var rejectedAlternatives: [String]
  public var writerLine: String?
  public var stepKey: String?
  public var payload: JSONValue?
  public var links: NotebookLinks
  public var idea: NotebookIdeaRejection?

  public init(
    kind: LedgerEntryKind, decidedBy: LedgerDecidedBy, statement: String, why: String? = nil, rejectedAlternatives: [String] = [], writerLine: String? = nil,
    stepKey: String? = nil, payload: JSONValue? = nil, links: NotebookLinks = NotebookLinks(), idea: NotebookIdeaRejection? = nil
  ) {
    self.kind = kind
    self.decidedBy = decidedBy
    self.statement = statement
    self.why = why
    self.rejectedAlternatives = rejectedAlternatives
    self.writerLine = writerLine
    self.stepKey = stepKey
    self.payload = payload
    self.links = links
    self.idea = idea
  }
}

// ledger.types.ts:46 and ledger.dto.ts:80: an omitted field carries over when the kind is kept, an empty string clears
public struct NotebookRewrite: Sendable, Equatable {
  public var kind: LedgerEntryKind?
  public var statement: String
  public var why: String?
  public var writerLine: String?
  public var rejectedAlternatives: [String]?
  public var payload: [String: JSONValue]?

  public init(
    kind: LedgerEntryKind? = nil, statement: String, why: String? = nil, writerLine: String? = nil, rejectedAlternatives: [String]? = nil, payload: [String: JSONValue]? = nil
  ) {
    self.kind = kind
    self.statement = statement
    self.why = why
    self.writerLine = writerLine
    self.rejectedAlternatives = rejectedAlternatives
    self.payload = payload
  }
}
