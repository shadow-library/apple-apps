import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/refinement/apply/promise.handler.ts over Domain/Story/Promises
enum StoryPromises {
  // promise.handler.ts:112: any record under the key, dropped or not, is refused; the opening chapter defaults to the next writable one
  static func create(_ create: PromiseCreate, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let promise = ref(create.kind, create.key)
    if case .live = try presence(of: promise, novel: novel, in: transaction) { throw .domain(.promiseExists(promise)) }
    if create.openedChapter == nil { try requireChaptersReadable(novel: novel, in: transaction) }
    try handlerDomain { () throws(DomainError) in
      try Promises.create(novel: novel, promise, label: create.label, openedChapter: create.openedChapter, in: &transaction)
    }
    return HandlerOutcome(inverse: StoryRestore.promiseDeletion(promise).json)
  }

  // promise.handler.ts:124. The chapter a promise last advanced in has no native field (a pipeline observation), so naming it refuses the op; one ahead of
  // the latest chapter is refused as the reference refuses it
  static func update(_ update: PromiseUpdate, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let promise = ref(update.kind, update.key)
    let existing = try live(promise, novel: novel, in: transaction)
    if let advanced = update.lastAdvancedChapter {
      try requireChaptersReadable(novel: novel, in: transaction)
      throw .refused(lastAdvancedRefusal(advanced, latest: try latestChapter(novel: novel, in: transaction)))
    }
    let settlement = update.status.map { $0 == .paidOff ? PromiseSettlement.payOff : .reopen }
    if settlement == .payOff { try requireChaptersReadable(novel: novel, in: transaction) }
    try handlerDomain { () throws(DomainError) in try Promises.update(novel: novel, promise, label: update.label, settlement: settlement, in: &transaction) }
    return HandlerOutcome(inverse: existing.restore.json)
  }

  static func lastAdvancedRefusal(_ chapter: Int, latest: Int) -> ApplyRefusal {
    chapter > latest ? .lastAdvancedAhead(chapter: chapter, latest: latest) : .lastAdvancedUntracked
  }

  // promise.handler.ts:167: someday clears every target; otherwise each target the op names, null included, replaces the promise's
  static func setPayoff(_ payoff: PromiseSetPayoff, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let promise = ref(payoff.kind, payoff.key)
    let existing = try live(promise, novel: novel, in: transaction)
    let change: PayoffChange =
      payoff.someday == true
      ? .someday(dormant: payoff.dormant)
      : .target(milestone: kept(payoff.payoffMilestoneKey), volume: kept(payoff.payoffVolumeKey), window: kept(payoff.payoffWindow), dormant: payoff.dormant)
    try handlerDomain { () throws(DomainError) in try Promises.setPayoff(novel: novel, promise, change, in: &transaction) }
    return HandlerOutcome(inverse: existing.payoff.json)
  }

  // promise.handler.ts:192: a drop keeps the record and its chapter
  static func drop(_ drop: PromiseDrop, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let promise = ref(drop.kind, drop.key)
    let existing = try live(promise, novel: novel, in: transaction)
    try handlerDomain { () throws(DomainError) in try Promises.drop(novel: novel, promise, in: &transaction) }
    return HandlerOutcome(inverse: existing.restore.json)
  }

  // promise.handler.ts:133-145 for a captured restore: the label, status and chapter exactly as they were, with no trimming or fallback
  static func restore(_ restore: PromiseRestore, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let promise = restore.promise
    let existing = try live(promise, novel: novel, in: transaction)
    switch existing {
    case .thread(let thread):
      var edit = ThreadEdit()
      edit.summary = .set(restore.label)
      edit.status = .set(ThreadProgress(state: StoredEnum(rawValue: restore.status), chapter: restore.chapter))
      try handlerDomain { () throws(DomainError) in try transaction.edit(ThreadRecord.self, thread.ref, edit.fields) }
    case .mystery(let mystery):
      guard let question = restore.label else { throw .refused(.malformedInverse) }
      var edit = MysteryEdit()
      edit.question = .set(question)
      edit.status = .set(MysteryProgress(state: StoredEnum(rawValue: restore.status), chapter: restore.chapter))
      try handlerDomain { () throws(DomainError) in try transaction.edit(MysteryRecord.self, mystery.ref, edit.fields) }
    }
    return HandlerOutcome(inverse: existing.restore.json)
  }

  static func restorePayoff(_ restore: PayoffRestore, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let existing = try live(restore.promise, novel: novel, in: transaction)
    let change = PayoffChange.target(milestone: .set(restore.milestone), volume: .set(restore.volume), window: .set(restore.window), dormant: restore.dormant)
    try handlerDomain { () throws(DomainError) in try Promises.setPayoff(novel: novel, restore.promise, change, in: &transaction) }
    return HandlerOutcome(inverse: existing.payoff.json)
  }

  // promise.handler.ts:195: the inverse of a create removes the promise it made
  static func delete(_ promise: PromiseRef, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    _ = try live(promise, novel: novel, in: transaction)
    try handlerDomain { () throws(DomainError) in try Promises.remove(novel: novel, promise, in: &transaction) }
    return HandlerOutcome()
  }

  private enum Existing: Sendable, Equatable {
    case thread(ThreadRecord)
    case mystery(MysteryRecord)

    var promise: PromiseRef {
      switch self {
      case .thread(let thread): .thread(thread.thread)
      case .mystery(let mystery): .mystery(mystery.mystery)
      }
    }

    var restore: StoryRestore {
      switch self {
      case .thread(let thread): .promise(PromiseRestore(thread, promise: promise))
      case .mystery(let mystery): .promise(PromiseRestore(mystery, promise: promise))
      }
    }

    var payoff: StoryRestore {
      switch self {
      case .thread(let thread):
        .payoff(PayoffRestore(promise: promise, milestone: thread.payoffMilestone, volume: thread.payoffVolume, window: thread.payoffWindow, dormant: thread.dormant))
      case .mystery(let mystery):
        .payoff(
          PayoffRestore(promise: promise, milestone: mystery.payoffMilestone, volume: mystery.payoffVolume, window: mystery.payoffWindow, dormant: mystery.dormant))
      }
    }
  }

  private static func ref(_ kind: PromiseKind, _ key: String) -> PromiseRef {
    switch kind {
    case .thread: .thread(key)
    case .mystery: .mystery(key)
    }
  }

  private static func live(_ promise: PromiseRef, novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> Existing {
    guard case .live(let existing) = try presence(of: promise, novel: novel, in: transaction) else { throw .domain(.promiseNotFound(promise)) }
    return existing
  }

  private static func presence(of promise: PromiseRef, novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> Presence<Existing> {
    switch promise {
    case .thread(let key):
      switch try handlerDomain(
        "promise:thread:\(key)", ThreadRecord.ref(novel: novel, thread: key),
        { () throws(DomainError) in try transaction.presence(ThreadRecord.ref(novel: novel, thread: key), as: ThreadRecord.self) })
      {
      case .live(let record): return .live(.thread(record))
      case .removed(let record): return .removed(.thread(record))
      case .absent: return .absent
      }
    case .mystery(let key):
      switch try handlerDomain(
        "promise:mystery:\(key)", MysteryRecord.ref(novel: novel, mystery: key),
        { () throws(DomainError) in try transaction.presence(MysteryRecord.ref(novel: novel, mystery: key), as: MysteryRecord.self) })
      {
      case .live(let record): return .live(.mystery(record))
      case .removed(let record): return .removed(.mystery(record))
      case .absent: return .absent
      }
    }
  }

  // next-chapter.ts:11 and promise.handler.ts:71 read every draft and final chapter of the novel
  private static func requireChaptersReadable(novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) {
    try requireStoryReadable(DraftRecord.self, novel: novel, in: transaction)
    try requireStoryReadable(FinalChapterRecord.self, novel: novel, in: transaction)
  }

  // promise.handler.ts:71
  private static func latestChapter(novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> Int {
    let drafted = try handlerDomain { () throws(DomainError) in try transaction.listing(DraftRecord.self, novel: novel).map(\.chapter) }
    let finalized = try handlerDomain { () throws(DomainError) in try transaction.listing(FinalChapterRecord.self, novel: novel).map(\.chapter) }
    return (drafted + finalized).max() ?? 0
  }

  private static func kept<Value: Sendable & Equatable & JSONWritable>(_ value: OpValue<Value>) -> FieldChange<Value?> {
    switch value {
    case .omitted: .keep
    case .null: .set(nil)
    case .set(let value): .set(value)
    }
  }
}
