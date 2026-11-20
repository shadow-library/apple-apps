import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowText

/// A promise as the author's record and the winning canons' observations leave it. `closedChapter` is a thread's closed chapter or a mystery's resolved one,
/// `text` its summary or question; `lastAdvancedChapter` is the latest chapter that observed it.
public struct PromiseStateEntry: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_promise_state"

  public let novel: UUID
  let promise: PromiseKind
  public let key: String
  public let status: String
  public let openedChapter: Int?
  public let closedChapter: Int?
  public let text: String?
  public let intentionallyOpen: Bool
  public let truthFact: String?
  public let lastAdvancedChapter: Int?

  enum CodingKeys: String, CodingKey {
    case novel
    case promise
    case key
    case status
    case openedChapter = "opened_chapter"
    case closedChapter = "closed_chapter"
    case text
    case intentionallyOpen = "intentionally_open"
    case truthFact = "truth_fact"
    case lastAdvancedChapter = "last_advanced_chapter"
  }
}

/// The author's promise record with the clock of the register each value sits in.
struct AuthoredPromise: Equatable {
  var status: String
  var statusChapter: Int?
  var statusClock: HLCTimestamp?
  var text: String?
  var textClock: HLCTimestamp?
  var dormant: Bool
  var openedChapter: Int?
  var truthFact: String?
  var truthClock: HLCTimestamp?
}

/// A kept promise item of one winning canon.
struct PromiseObservation: Equatable {
  var chapter: Int
  var clock: HLCTimestamp
  var status: String
  var text: String?
  var intentionallyOpen: Bool?
  var truthFact: String?
}

/// apps/novel-forge-server/src/modules/ai/graphs/apply-continuity.ts:124-222 as a fold: a dropped promise is never reopened or closed, one that exists keeps its
/// dormant-on-purpose flag, a summary or truth is only ever replaced, and the first observation of a promise the author never recorded creates it. Pipelines
/// never write the record (phase 5 schema conventions), so a register the author wrote after a canon outranks what that canon observed.
enum PromiseFold {
  static func fold(_ kind: PromiseKind, authored: AuthoredPromise?, observations: [PromiseObservation]) -> PromiseState? {
    let closing = kind == .thread ? ThreadStatus.closed.rawValue : MysteryStatus.resolved.rawValue
    var state = authored.map { record in
      PromiseState(
        status: record.status, openedChapter: record.openedChapter, closedChapter: record.status == closing ? record.statusChapter : nil, text: record.text,
        intentionallyOpen: record.dormant, truthFact: record.truthFact, lastAdvancedChapter: nil)
    }
    for observation in observations {
      guard var current = state else {
        state = PromiseState(
          status: observation.status, openedChapter: observation.chapter, closedChapter: observation.status == closing ? observation.chapter : nil,
          text: kind == .thread ? observation.text : observation.text ?? "", intentionallyOpen: observation.intentionallyOpen ?? false,
          truthFact: observation.truthFact, lastAdvancedChapter: observation.chapter)
        continue
      }
      let outranks = { (clock: HLCTimestamp?) in clock.map { $0 > observation.clock } ?? false }
      if !outranks(authored?.statusClock), current.status != ThreadStatus.dropped.rawValue {
        if observation.status == closing { current.closedChapter = observation.chapter }
        current.status = observation.status
      }
      let text = kind == .thread ? observation.text : observation.text.flatMap { $0.isEmpty ? nil : $0 }
      if let text, !outranks(authored?.textClock) { current.text = text }
      if let truth = observation.truthFact, !outranks(authored?.truthClock) { current.truthFact = truth }
      current.lastAdvancedChapter = observation.chapter
      state = current
    }
    return state
  }
}

struct PromiseState: Equatable {
  var status: String
  var openedChapter: Int?
  var closedChapter: Int?
  var text: String?
  var intentionallyOpen: Bool
  var truthFact: String?
  var lastAdvancedChapter: Int?
}

private struct PromiseSlot: Hashable, Comparable {
  let kind: PromiseKind
  let key: JSString

  static func < (left: PromiseSlot, right: PromiseSlot) -> Bool {
    left.kind == right.kind ? left.key < right.key : left.kind.rawValue < right.kind.rawValue
  }
}

/// Every promise the author recorded or a winning canon observed; a record that cannot be read shows nothing, its observations included.
public struct PromiseStateDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_promise_state (
      novel BLOB NOT NULL, promise TEXT NOT NULL, key TEXT NOT NULL, status TEXT NOT NULL, opened_chapter INTEGER, closed_chapter INTEGER, text TEXT,
      intentionally_open INTEGER NOT NULL, truth_fact TEXT, last_advanced_chapter INTEGER, PRIMARY KEY (novel, promise, key)
    ) STRICT, WITHOUT ROWID;
    """

  static let recordKinds: [NovelForgeKind] = [.thread, .mystery]

  public init() {}

  public var inputs: [DerivationInput<UUID>] {
    [
      .outputs(of: CanonBindingDerivation.self) { [$0.novel] },
      .outputs(of: RecordIndexDerivation.self) { row in Self.recordKinds.contains(row.kind) ? row.novel.map { [$0] } ?? [] : [] },
    ]
  }

  public static func key(of output: PromiseStateEntry) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<PromiseStateEntry> { PromiseStateEntry.filter(Column("novel") == novel) }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    let records = try context.fetchAll(IndexedRecord.filter(Self.recordKinds.map(\.rawValue).contains(Column("kind")))).compactMap(\.novel)
    return try CanonCharacters.novels(in: context).union(records)
  }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [PromiseStateEntry] {
    var observed = [PromiseSlot: [PromiseObservation]]()
    for binding in try CanonBinding.all(of: novel, in: context) {
      for change in binding.kept {
        switch change {
        case .thread(let thread):
          let observation = PromiseObservation(
            chapter: binding.chapter, clock: binding.clock, status: thread.status.rawValue, text: thread.summary, intentionallyOpen: thread.intentionallyOpen)
          observed[PromiseSlot(kind: .thread, key: JSString(thread.threadKey.jsNormalize(.nfc))), default: []].append(observation)
        case .mystery(let mystery):
          let observation = PromiseObservation(
            chapter: binding.chapter, clock: binding.clock, status: mystery.status.rawValue, text: mystery.question, intentionallyOpen: mystery.intentionallyOpen,
            truthFact: mystery.truthFactKey)
          observed[PromiseSlot(kind: .mystery, key: JSString(mystery.mysteryKey.jsNormalize(.nfc))), default: []].append(observation)
        default:
          continue
        }
      }
    }

    var authored = [PromiseSlot: AuthoredPromise]()
    var hidden = Set<PromiseSlot>()
    var since = [PromiseSlot: HLCTimestamp]()
    let rows = try context.fetchAll(IndexedRecord.filter(Column("novel") == novel && Self.recordKinds.map(\.rawValue).contains(Column("kind"))))
    for row in rows {
      let state = try context.records.state(of: row.ref, scope: .vault)
      guard let state, case .record(let fields) = state, let key = try? NovelForgeKey(reading: state, of: row.ref) else { continue }
      let clock = { (name: String) in fields[field: name]?.clock }
      switch key.components {
      case .thread(let thread):
        let slot = PromiseSlot(kind: .thread, key: JSString(thread))
        guard case .readable(let entry) = ThreadRecord.reading(state, of: row.ref) else {
          hidden.insert(slot)
          continue
        }
        since[slot] = state.liveSince
        if entry.isRemoved { continue }
        let record = entry.record
        authored[slot] = AuthoredPromise(
          status: record.status.state.rawValue, statusChapter: record.status.chapter, statusClock: clock(ThreadField.status.rawValue), text: record.summary,
          textClock: clock(ThreadField.summary.rawValue), dormant: record.dormant, openedChapter: record.openedChapter)
      case .mystery(let mystery):
        let slot = PromiseSlot(kind: .mystery, key: JSString(mystery))
        guard case .readable(let entry) = MysteryRecord.reading(state, of: row.ref) else {
          hidden.insert(slot)
          continue
        }
        since[slot] = state.liveSince
        if entry.isRemoved { continue }
        let record = entry.record
        authored[slot] = AuthoredPromise(
          status: record.status.state.rawValue, statusChapter: record.status.chapter, statusClock: clock(MysteryField.status.rawValue), text: record.question,
          textClock: clock(MysteryField.question.rawValue), dormant: record.dormant, openedChapter: record.openedChapter, truthFact: record.truthFact,
          truthClock: clock(MysteryField.truthFact.rawValue))
      default:
        continue
      }
    }

    // promise.handler.ts:196-197 deletes the row with its history and apply-continuity.ts:153-168 creates it again, so an observation counts only after the
    // record's latest create, restore or removal.
    return Set(authored.keys).union(observed.keys).subtracting(hidden).sorted().compactMap { slot in
      let observations = (observed[slot] ?? []).filter { observation in since[slot].map { observation.clock > $0 } ?? true }
      return PromiseFold.fold(slot.kind, authored: authored[slot], observations: observations).map { state in
        PromiseStateEntry(
          novel: novel, promise: slot.kind, key: slot.key.value, status: state.status, openedChapter: state.openedChapter, closedChapter: state.closedChapter,
          text: state.text, intentionallyOpen: state.intentionallyOpen, truthFact: state.truthFact, lastAdvancedChapter: state.lastAdvancedChapter)
      }
    }
  }
}
