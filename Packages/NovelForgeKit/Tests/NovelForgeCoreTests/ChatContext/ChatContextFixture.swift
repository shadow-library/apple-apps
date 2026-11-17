import Foundation
import Testing

@testable import NovelForgeCore

struct ChatContextFixture: Decodable {
  struct Labeled: Decodable {
    let key: String
    let rendered: String
  }

  struct Join: Decodable {
    let sections: [ChatPackSection]
    let joined: String
    let stable: String
    let volatile: String
  }

  struct Fit: Decodable {
    let section: ChatPackSection
    let cap: Int
    let expected: ChatPackSection
  }

  struct Story: Decodable {
    let story: ChatPackStory
    let expected: String
  }

  struct Notes: Decodable {
    let notes: String
    let paragraphs: [String]
    let expected: String?
  }

  struct Progress: Decodable {
    let items: [ChatPackProgressLine]
    let expected: String?
  }

  struct Volumes: Decodable {
    let volumes: [ChatPackVolume]
    let expected: String
  }

  struct Notebook: Decodable {
    let entries: [ChatPackLedgerEntry]
    let maxTokens: Int?
    let expected: String
    let loneSurrogate: Bool
  }

  struct Run: Decodable {
    let maxTokens: Int
    let expected: String
  }

  struct NotebookSweep: Decodable {
    let entries: [ChatPackLedgerEntry]
    let runs: [Run]
  }

  struct LineSweep: Decodable {
    let lines: [String]
    let leftOut: String
    let runs: [Run]
  }

  struct Promises: Decodable {
    let promises: [ChatPackPromise]
    let next: Int
    let milestones: [[String]]
    let volumes: [[String]]
    let expected: String
  }

  struct Payoff: Decodable {
    let window: Int?
    let milestone: String?
    let volume: String?
    let expected: String
  }

  struct Inventory: Decodable {
    let entities: [ChatPackEntity]
    let pages: [ChatPackPage]
    let facts: [ChatPackFact]
    let milestones: [ChatPackMilestone]
    let expected: String
  }

  struct WalledChapter: Decodable {
    let number: Int
    let title: String?
    let summary: String?
  }

  struct WalledDraft: Decodable {
    let chapter: Int
    let title: String?
    let summary: String?
  }

  struct Chapters: Decodable {
    let chapters: [ChatPackChapter]
    let drafts: [ChatPackDraft]
    let planned: [Int]
    let briefs: [ChatPackBrief]
    let next: Int
    let walledChapters: [WalledChapter]
    let walledDrafts: [WalledDraft]
    let index: String?
    let handoff: String
  }

  struct Awaiting: Decodable {
    let awaiting: ChatPackAwaitingAuthor
    let expected: String?
  }

  struct Ending: Decodable {
    let chapter: Int
    let cap: Int
    let row: ChatPackEndingRow?
    let draft: ChatPackEndingDraft?
    let expected: ChatPackSection?
  }

  struct Pipeline: Decodable {
    let pipeline: ChatPackPipeline
    let expected: String
  }

  struct Changes: Decodable {
    let changes: ChatPackChanges
    let expected: [String]
  }

  struct Pack: Decodable {
    struct Expected: Decodable {
      let sections: [ChatPackSection]
      let omitted: [ChatPackOmission]
      let usedTokens: Int
      let budgetTokens: Int
      let renderedLength: Int
    }

    let inputs: ChatPackInputs
    let promptTokens: Int
    let requestTokens: Int
    let expected: Expected
  }

  struct Constants: Decodable {
    struct Caps: Decodable {
      let story: Int
      let notebook: Int
      let authorNotes: Int
      let volumes: Int
      let promises: Int
      let inventory: Int
      let chapterIndex: Int
      let handoff: Int
      let latestEnding: Int
      let latestState: Int
      let changedSince: Int
      let progress: Int
    }

    struct Labels: Decodable {
      let ending: String
      let endingQuestion: String
      let laterVolume: String
    }

    let requestBudget: Int
    let packFloor: Int
    let packMargin: Int
    let messageAllowance: Int
    let historyAllowance: Int
    let caps: Caps
    let labels: Labels
    let previousEndingTail: Int
    let turnedDownLimit: Int
  }

  let labels: [Labeled]
  let joins: [Join]
  let fits: [Fit]
  let story: [Story]
  let notes: [Notes]
  let progress: [Progress]
  let volumes: [Volumes]
  let notebook: [Notebook]
  let notebookSweeps: [NotebookSweep]
  let fitLines: [LineSweep]
  let promises: [Promises]
  let payoff: [Payoff]
  let inventory: [Inventory]
  let chapters: [Chapters]
  let awaiting: [Awaiting]
  let endings: [Ending]
  let pipeline: [Pipeline]
  let changes: [Changes]
  let packs: [Pack]
  let constants: Constants

  static let shared = Result { try ReferenceFixture.decode(ChatContextFixture.self, from: "chat-context/chat-context.json") }
}

func expectSame(_ actual: String?, _ expected: String?, _ label: @autoclosure () -> String, sourceLocation: SourceLocation = #_sourceLocation) {
  switch (actual, expected) {
  case (nil, nil): return
  case (let actual?, let expected?): #expect(actual.jsEquals(expected), Comment(rawValue: label()), sourceLocation: sourceLocation)
  default: #expect(actual == expected, Comment(rawValue: label()), sourceLocation: sourceLocation)
  }
}

func expectSame(_ actual: ChatPackSection?, _ expected: ChatPackSection?, _ label: @autoclosure () -> String, sourceLocation: SourceLocation = #_sourceLocation) {
  guard let actual, let expected else {
    #expect(actual == nil && expected == nil, Comment(rawValue: label()), sourceLocation: sourceLocation)
    return
  }
  expectSame(actual.rendered, expected.rendered, "\(label()) rendered", sourceLocation: sourceLocation)
  #expect(actual.key.jsEquals(expected.key), Comment(rawValue: "\(label()) key"), sourceLocation: sourceLocation)
  #expect(actual.tier == expected.tier, Comment(rawValue: "\(label()) tier"), sourceLocation: sourceLocation)
  #expect(actual.segment == expected.segment, Comment(rawValue: "\(label()) segment"), sourceLocation: sourceLocation)
  #expect(actual.tokens == expected.tokens, Comment(rawValue: "\(label()) tokens"), sourceLocation: sourceLocation)
  #expect(actual.truncated == expected.truncated, Comment(rawValue: "\(label()) truncated"), sourceLocation: sourceLocation)
  #expect(actual.sourceRefs == expected.sourceRefs, Comment(rawValue: "\(label()) sourceRefs"), sourceLocation: sourceLocation)
  #expect(actual.required == expected.required, Comment(rawValue: "\(label()) required"), sourceLocation: sourceLocation)
  #expect(actual.priority == expected.priority, Comment(rawValue: "\(label()) priority"), sourceLocation: sourceLocation)
}
