import Foundation
import ShadowCore
import ShadowStore
import ShadowText

// apps/novel-forge-server/src/modules/refinement/apply/{premise,volume,milestone,fact,promise}.handler.ts. Each handler reads what it needs and refuses before
// its first write; the inverse is captured from the record as it stands right before the write. A redo is an apply, and the intent changes nothing here:
// apply.types.ts:32 concerns a plan's content mode only.
enum StoryHandlers: ContentOpHandler {
  static func apply(_ operation: ChangeOperation, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let novel = context.novel
    switch operation {
    case .premiseUpdate(let update): return try updatePremise(update, novel: novel, in: &transaction)
    case .volumeUpsert(let upsert): return try StoryPlanState.upsertVolume(upsert, novel: novel, in: &transaction)
    case .volumeRemove(let removal): return try StoryPlanState.removeVolume(removal.volumeKey, novel: novel, in: &transaction)
    case .milestoneUpsert(let upsert): return try StoryPlanState.upsertMilestone(upsert, novel: novel, in: &transaction)
    case .milestoneRemove(let removal): return try StoryPlanState.removeMilestone(removal.milestoneKey, novel: novel, in: &transaction)
    case .factUpsert(let upsert): return try StoryPlanState.upsertFact(upsert, novel: novel, in: &transaction)
    case .factRemove(let removal): return try StoryPlanState.removeFact(removal.factKey, novel: novel, in: &transaction)
    case .promiseCreate(let create): return try StoryPromises.create(create, novel: novel, in: &transaction)
    case .promiseUpdate(let update): return try StoryPromises.update(update, novel: novel, in: &transaction)
    case .promiseSetPayoff(let payoff): return try StoryPromises.setPayoff(payoff, novel: novel, in: &transaction)
    case .promiseDrop(let drop): return try StoryPromises.drop(drop, novel: novel, in: &transaction)
    default: throw .noHandler(operation.type)
    }
  }

  /// Writes back what an inverse captured (proposal-revert.service.ts:148 applies it as an op): the content verbatim, with none of the trimming or
  /// normalising an op's own write does, so the records land on the content hash they had before the change.
  static func undo(_ inverse: OrderedJSONObject, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let restore: StoryRestore
    do throws(ApplyRefusal) {
      restore = try StoryRestore(inverse)
    } catch {
      throw .refused(error)
    }
    let novel = context.novel
    switch restore {
    case .premise(let fields): return try restorePremise(fields, novel: novel, in: &transaction)
    case .volume(let volume): return try StoryPlanState.restoreVolume(volume, novel: novel, in: &transaction)
    case .volumeRemoval(let key): return try StoryPlanState.removeVolume(key, novel: novel, in: &transaction)
    case .milestone(let milestone): return try StoryPlanState.restoreMilestone(milestone, novel: novel, in: &transaction)
    case .milestoneRemoval(let key): return try StoryPlanState.removeMilestone(key, novel: novel, in: &transaction)
    case .fact(let fact): return try StoryPlanState.restoreFact(fact, novel: novel, in: &transaction)
    case .factRemoval(let key): return try StoryPlanState.removeFact(key, novel: novel, in: &transaction)
    case .promise(let promise): return try StoryPromises.restore(promise, novel: novel, in: &transaction)
    case .payoff(let payoff): return try StoryPromises.restorePayoff(payoff, novel: novel, in: &transaction)
    case .promiseDeletion(let promise): return try StoryPromises.delete(promise, novel: novel, in: &transaction)
    }
  }

  // premise.handler.ts:25: premise, brief and themes as given, the instructions as the novel's writing style (its additions to the defaults), the story fields
  // trimmed with blank as none
  private static func updatePremise(_ update: PremiseUpdate, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let record = try liveNovel(novel, in: transaction)
    var edit = NovelEdit()
    if let premise = update.premise { edit.premise = .set(premise) }
    if let brief = update.brief { edit.brief = .set(brief) }
    if let themes = update.themes { edit.themes = .set(themes) }
    if let instructions = update.instructions { edit.writingStyle = .set(writingInstructionAdditions(instructions)) }
    if let theme = update.theme { edit.theme = .set(trimmedOrNil(theme)) }
    if let promise = update.readerPromise { edit.readerPromise = .set(trimmedOrNil(promise)) }
    if let protagonist = update.protagonistKey { edit.protagonist = .set(trimmedOrNil(protagonist)) }
    if let opposition = update.opposition { edit.opposition = .set(trimmedOrNil(opposition)) }
    if let question = update.endingQuestion { edit.endingQuestion = .set(trimmedOrNil(question)) }
    if let ending = update.ending { edit.ending = .set(trimmedOrNil(ending)) }
    let inverse = StoryRestore.premise(update.named.map { ($0, $0.stored(in: record)) })
    try handlerDomain { () throws(DomainError) in try transaction.edit(NovelRecord.self, NovelForgeKey.novel(novel), edit.fields) }
    return HandlerOutcome(inverse: inverse.json)
  }

  private static func restorePremise(_ fields: [(field: PremiseField, value: OrderedJSON)], novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError)
    -> HandlerOutcome
  {
    let record = try liveNovel(novel, in: transaction)
    var edit = NovelEdit()
    do throws(ApplyRefusal) {
      for (field, value) in fields { try field.restore(value, into: &edit) }
    } catch {
      throw .refused(error)
    }
    let inverse = StoryRestore.premise(fields.map { ($0.field, $0.field.stored(in: record)) })
    try handlerDomain { () throws(DomainError) in try transaction.edit(NovelRecord.self, NovelForgeKey.novel(novel), edit.fields) }
    return HandlerOutcome(inverse: inverse.json)
  }

  // premise.handler.ts:14
  private static func liveNovel(_ novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> NovelRecord {
    guard
      case .live(let record) = try handlerDomain(
        "premise", NovelForgeKey.novel(novel), { () throws(DomainError) in try transaction.presence(NovelForgeKey.novel(novel), as: NovelRecord.self) })
    else {
      throw .domain(.novelNotFound(novel))
    }
    return record
  }
}

extension PremiseUpdate {
  // premise.handler.ts:16-21: the fields the op names, in the order the reference captures them
  var named: [PremiseField] {
    PremiseField.allCases.filter { field in
      switch field {
      case .premise: premise != nil
      case .brief: brief != nil
      case .themes: themes != nil
      case .instructions: instructions != nil
      case .theme: theme != nil
      case .readerPromise: readerPromise != nil
      case .protagonistKey: protagonistKey != nil
      case .opposition: opposition != nil
      case .endingQuestion: endingQuestion != nil
      case .ending: ending != nil
      }
    }
  }
}

/// A rule that reads other records of the novel cannot hold over records this device cannot read, so they refuse the change rather than count as absent.
func requireStoryReadable<Record: KeyedRecord>(_: Record.Type, novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) {
  let unreadable = try handlerStore { () throws(StoreError) in try Record.listing(novel: novel, in: transaction).unreadable }
  guard unreadable == 0 else { throw .refused(.unreadableReferences(kind: Record.kind.rawValue, count: unreadable)) }
}
