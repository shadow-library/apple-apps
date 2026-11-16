import Foundation
import ShadowStore

public enum PromiseSettlement: Sendable, Equatable {
  case reopen
  case payOff
}

public enum PayoffChange: Sendable, Equatable {
  case someday(dormant: Bool? = nil)
  case target(milestone: FieldChange<String?> = .keep, volume: FieldChange<String?> = .keep, window: FieldChange<Int?> = .keep, dormant: Bool? = nil)
}

// apps/novel-forge-server/src/modules/refinement/apply/promise.handler.ts; a pipeline's observations (last advanced chapter) get kinds of their own
public enum Promises {
  // promise.handler.ts:112
  public static func create(novel: UUID, _ promise: PromiseRef, label: String, openedChapter: Int? = nil, in transaction: inout WriteTransaction) throws(StoryError) {
    try requireSpacelessKey(promise.key, field: "key")
    try requireNonBlank(label, field: "label")
    try transaction.requireNovel(novel)
    if case .live = try presence(of: promise, novel: novel, in: transaction) { throw .promiseExists(promise) }
    var opened = openedChapter
    if opened == nil { opened = try nextChapter(novel: novel, in: transaction) }
    switch promise {
    case .thread(let key): try transaction.create(ThreadRecord(novel: novel, thread: key, summary: label, openedChapter: opened))
    case .mystery(let key): try transaction.create(MysteryRecord(novel: novel, mystery: key, question: label, openedChapter: opened))
    }
  }

  // promise.handler.ts:124: paying off stamps the latest chapter, reopening clears it
  public static func update(
    novel: UUID, _ promise: PromiseRef, label: String? = nil, settlement: PromiseSettlement? = nil, in transaction: inout WriteTransaction
  ) throws(StoryError) {
    try requireSpacelessKey(promise.key, field: "key")
    guard case .live(let existing) = try presence(of: promise, novel: novel, in: transaction) else { throw .promiseNotFound(promise) }
    var stamped: Int?
    if settlement == .payOff { stamped = try latestChapter(novel: novel, in: transaction) }
    switch existing {
    case .thread(let thread):
      var edit = ThreadEdit()
      if let label { edit.summary = .set(trimmedOrNil(label) ?? thread.summary ?? thread.thread) }
      if let settlement { edit.status = .set(ThreadProgress(state: .known(settlement == .payOff ? .closed : .open), chapter: stamped)) }
      try transaction.edit(ThreadRecord.self, thread.ref, edit.fields)
    case .mystery(let mystery):
      var edit = MysteryEdit()
      if let label { edit.question = .set(trimmedOrNil(label) ?? mystery.question) }
      if let settlement { edit.status = .set(MysteryProgress(state: .known(settlement == .payOff ? .resolved : .open), chapter: stamped)) }
      try transaction.edit(MysteryRecord.self, mystery.ref, edit.fields)
    }
  }

  // promise.handler.ts:167
  public static func setPayoff(novel: UUID, _ promise: PromiseRef, _ payoff: PayoffChange, in transaction: inout WriteTransaction) throws(StoryError) {
    try requireSpacelessKey(promise.key, field: "key")
    guard case .live(let existing) = try presence(of: promise, novel: novel, in: transaction) else { throw .promiseNotFound(promise) }
    let (milestone, volume, window, dormant) = payoff.changes
    switch existing {
    case .thread(let thread):
      var edit = ThreadEdit()
      edit.payoffMilestone = milestone
      edit.payoffVolume = volume
      edit.payoffWindow = window
      if let dormant { edit.dormant = .set(dormant) }
      try transaction.edit(ThreadRecord.self, thread.ref, edit.fields)
    case .mystery(let mystery):
      var edit = MysteryEdit()
      edit.payoffMilestone = milestone
      edit.payoffVolume = volume
      edit.payoffWindow = window
      if let dormant { edit.dormant = .set(dormant) }
      try transaction.edit(MysteryRecord.self, mystery.ref, edit.fields)
    }
  }

  // promise.handler.ts:192: a drop keeps the record and the chapter it had
  public static func drop(novel: UUID, _ promise: PromiseRef, in transaction: inout WriteTransaction) throws(StoryError) {
    try requireSpacelessKey(promise.key, field: "key")
    guard case .live(let existing) = try presence(of: promise, novel: novel, in: transaction) else { throw .promiseNotFound(promise) }
    switch existing {
    case .thread(let thread):
      var edit = ThreadEdit()
      edit.status = .set(ThreadProgress(state: .known(.dropped), chapter: thread.status.chapter))
      try transaction.edit(ThreadRecord.self, thread.ref, edit.fields)
    case .mystery(let mystery):
      var edit = MysteryEdit()
      edit.status = .set(MysteryProgress(state: .known(.dropped), chapter: mystery.status.chapter))
      try transaction.edit(MysteryRecord.self, mystery.ref, edit.fields)
    }
  }

  public static func remove(novel: UUID, _ promise: PromiseRef, in transaction: inout WriteTransaction) throws(StoryError) {
    guard case .live(let existing) = try presence(of: promise, novel: novel, in: transaction) else { throw .promiseNotFound(promise) }
    switch existing {
    case .thread(let thread): try transaction.remove(ThreadRecord.self, thread.ref)
    case .mystery(let mystery): try transaction.remove(MysteryRecord.self, mystery.ref)
    }
  }

  public static func restore(novel: UUID, _ promise: PromiseRef, in transaction: inout WriteTransaction) throws(StoryError) {
    switch promise {
    case .thread(let key):
      switch try transaction.presence(ThreadRecord.ref(novel: novel, thread: key), as: ThreadRecord.self) {
      case .removed(let record): try transaction.restore(record)
      case .live: return
      case .absent: throw .promiseNotFound(promise)
      }
    case .mystery(let key):
      switch try transaction.presence(MysteryRecord.ref(novel: novel, mystery: key), as: MysteryRecord.self) {
      case .removed(let record): try transaction.restore(record)
      case .live: return
      case .absent: throw .promiseNotFound(promise)
      }
    }
  }

  // apps/novel-forge-server/src/common/next-chapter.ts:11
  private static func nextChapter(novel: UUID, in transaction: borrowing WriteTransaction) throws(StoryError) -> Int {
    let drafts = try transaction.listing(DraftRecord.self, novel: novel).map(\.chapter)
    let finals = try transaction.listing(FinalChapterRecord.self, novel: novel).map(\.chapter)
    return nextWritableChapter(draftChapters: drafts, finalizedChapters: finals)
  }

  // promise.handler.ts:71: the highest chapter that exists at all, drafted or final
  private static func latestChapter(novel: UUID, in transaction: borrowing WriteTransaction) throws(StoryError) -> Int {
    let drafted = try transaction.listing(DraftRecord.self, novel: novel).map(\.chapter)
    let finalized = try transaction.listing(FinalChapterRecord.self, novel: novel).map(\.chapter)
    return (drafted + finalized).max() ?? 0
  }

  private enum Existing: Sendable, Equatable {
    case thread(ThreadRecord)
    case mystery(MysteryRecord)
  }

  private static func presence(of promise: PromiseRef, novel: UUID, in transaction: borrowing WriteTransaction) throws(StoryError) -> Presence<Existing> {
    switch promise {
    case .thread(let key):
      switch try transaction.presence(ThreadRecord.ref(novel: novel, thread: key), as: ThreadRecord.self) {
      case .live(let record): return .live(.thread(record))
      case .removed(let record): return .removed(.thread(record))
      case .absent: return .absent
      }
    case .mystery(let key):
      switch try transaction.presence(MysteryRecord.ref(novel: novel, mystery: key), as: MysteryRecord.self) {
      case .live(let record): return .live(.mystery(record))
      case .removed(let record): return .removed(.mystery(record))
      case .absent: return .absent
      }
    }
  }
}

extension PayoffChange {
  fileprivate var changes: (milestone: FieldChange<String?>, volume: FieldChange<String?>, window: FieldChange<Int?>, dormant: Bool?) {
    switch self {
    case .someday(let dormant): (.set(nil), .set(nil), .set(nil), dormant)
    case .target(let milestone, let volume, let window, let dormant): (milestone, volume, window, dormant)
    }
  }
}
