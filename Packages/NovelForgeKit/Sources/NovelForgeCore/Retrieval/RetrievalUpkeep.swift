import Foundation
import GRDB
import OSLog
import ShadowCore
import ShadowStore

/// Keeps one vault's retrieval index level with its records on this device. Started, it catches up every novel; after that, each novel whose indexed
/// records changed, by a local write or a merge, once they have been quiet for `debounce`; after each catch-up it embeds what is pending in bounded batches.
/// One unit of work runs at a time, at background priority, and a waiting catch-up goes before the next embedding batch, so one novel's long embedding
/// never holds another's catch-up back and no novel is ever worked on twice at once. It reads again only after a commit that wrote to the record index,
/// which its own writes never touch, so they never wake it. A failed unit is logged and tried again 30 seconds later, the wait doubling
/// with each failure in a row up to `maximumRetryDelay`, or sooner when the novel changes meanwhile.
public actor RetrievalUpkeep {
  public static let defaultDebounce = Duration.seconds(3)
  /// Rows one embedding unit takes before a waiting catch-up gets its turn: a few seconds of the system model's time on prose chunks.
  static let embeddingBatch = 64
  static let maximumRetryDelay = Duration.seconds(30 * 60)
  static let logger = Logger(category: "retrieval.upkeep")

  struct Work: Sendable {
    let catchUp: @concurrent @Sendable (UUID) async throws(RetrievalError) -> Void
    let embed: @concurrent @Sendable (UUID, Int) async throws(RetrievalError) -> RetrievalEmbedding

    static func index(_ retrieval: NovelRetrieval) -> Work {
      Work(
        catchUp: { @concurrent novel throws(RetrievalError) in try await retrieval.catchUp(novel: novel) },
        embed: { @concurrent novel, limit throws(RetrievalError) in try await retrieval.embedPending(novel: novel, limit: limit) })
    }
  }

  private struct Item {
    let novel: UUID
    var catchUp: Bool
  }

  private struct Timer {
    let token: Int
    let catchUp: Bool
    let task: Task<Void, Never>
  }

  private let store: VaultStore
  private let work: Work
  private let debounce: Duration
  private let retryDelay: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private let noticed: (@Sendable (Set<UUID>) -> Void)?

  public private(set) var isRunning = false
  private var session = 0
  private var tokens = 0
  private var observing: Task<Void, Never>?
  private var worker: Task<Void, Never>?
  private var wake: AsyncStream<Void>.Continuation?
  private var timers: [UUID: Timer] = [:]
  private var queue: [Item] = []
  private var failures: [UUID: Int] = [:]
  private var seen: [UUID: Int]?

  public init(store: VaultStore, embedders: (any EmbedderProvider)?, debounce: Duration = defaultDebounce) {
    self.init(store: store, work: .index(NovelRetrieval(store: store, embedders: embedders)), debounce: debounce)
  }

  /// `noticed` hears every set of novels the upkeep saw change, the whole vault on a start included.
  init(
    store: VaultStore, work: Work, debounce: Duration = defaultDebounce, retryDelay: Duration = .seconds(30),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }, noticed: (@Sendable (Set<UUID>) -> Void)? = nil
  ) {
    self.store = store
    self.work = work
    self.debounce = debounce
    self.retryDelay = retryDelay
    self.sleep = sleep
    self.noticed = noticed
  }

  /// Catches every novel up and follows the records from now on; a start after `stop()` waits for the stopped pass to end before it runs one.
  public func start() {
    guard !isRunning else { return }
    isRunning = true
    session += 1
    let session = session
    let previous = worker
    let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    self.wake = wake
    worker = Task(priority: .background) { [weak self] in
      await previous?.value
      await self?.drain(wakes, session: session)
    }
    observing = Task(priority: .background) { [weak self] in await self?.observe(session: session) }
  }

  /// Cancels the running pass between two of its batches and forgets what was waiting; the next `start()` catches every novel up again.
  public func stop() {
    guard isRunning else { return }
    isRunning = false
    session += 1
    observing?.cancel()
    observing = nil
    worker?.cancel()
    wake?.finish()
    wake = nil
    for timer in timers.values { timer.task.cancel() }
    timers = [:]
    queue = []
    failures = [:]
    seen = nil
  }

  /// Per novel, a hash of every corpus record's kind, key, status and digest in the record index, which changes whenever what the index is built from may
  /// have changed and never with the index's own tables.
  static func fingerprints(in transaction: ReadTransaction) throws(StoreError) -> [UUID: Int] {
    try transaction.query { database in
      var hashers: [UUID: Hasher] = [:]
      let records = try IndexedRecord.filter(RetrievalCorpus.kinds.contains(Column("kind")) && Column("novel") != nil).order(Column("kind"), Column("key"))
        .fetchCursor(database)
      while let record = try records.next() {
        guard let novel = record.novel else { continue }
        hashers[novel, default: Hasher()].combine(record)
      }
      return hashers.mapValues { $0.finalize() }
    }
  }

  /// The novels the index holds sources of, so a start also catches up a novel whose records all left the corpus while nothing watched.
  static func indexedNovels(in transaction: ReadTransaction) throws(StoreError) -> Set<UUID> {
    try transaction.query { database in
      guard try database.tableExists(RetrievalTables.source) else { return [] }
      return Set(try UUID.fetchAll(database, sql: "SELECT DISTINCT novel FROM \(RetrievalTables.source)"))
    }
  }

  private func observe(session: Int) async {
    while !Task.isCancelled {
      do {
        let indexed = try await store.read { transaction in try Self.indexedNovels(in: transaction) }
        let observed = store.observeReads(writingTo: [IndexedRecord.databaseTableName]) { transaction in try Self.fingerprints(in: transaction) }
        for try await fingerprints in observed {
          changed(fingerprints, indexed: indexed, session: session)
        }
        return
      } catch {
        guard !Task.isCancelled else { return }
        Self.logger.error("Stopped following the records the retrieval index is built from code=\(Self.code(of: error), privacy: .public)")
        guard (try? await sleep(retryDelay)) != nil else { return }
      }
    }
  }

  private func changed(_ fingerprints: [UUID: Int], indexed: Set<UUID>, session: Int) {
    guard session == self.session else { return }
    guard let seen else {
      self.seen = fingerprints
      let novels = indexed.union(fingerprints.keys)
      noticed?(novels)
      for novel in novels.sorted(by: { $0.uuidString < $1.uuidString }) { enqueue(novel, catchUp: true) }
      return
    }
    self.seen = fingerprints
    let novels = Set(fingerprints.keys).union(seen.keys).filter { fingerprints[$0] != seen[$0] }
    guard !novels.isEmpty else { return }
    noticed?(novels)
    for novel in novels { schedule(novel, after: debounce, catchUp: true, session: session) }
  }

  /// Restarts the novel's wait, so a burst of writes is caught up once, `debounce` after the last of them; a change during a retry's wait replaces it.
  private func schedule(_ novel: UUID, after delay: Duration, catchUp: Bool, session: Int) {
    let catchUp = catchUp || timers[novel]?.catchUp == true
    timers[novel]?.task.cancel()
    tokens += 1
    let (token, sleep) = (tokens, sleep)
    let task = Task(priority: .background) { [weak self] in
      guard (try? await sleep(delay)) != nil else { return }
      await self?.elapsed(novel, token: token, session: session)
    }
    timers[novel] = Timer(token: token, catchUp: catchUp, task: task)
  }

  private func elapsed(_ novel: UUID, token: Int, session: Int) {
    guard session == self.session, let timer = timers[novel], timer.token == token else { return }
    timers[novel] = nil
    enqueue(novel, catchUp: timer.catchUp)
  }

  private func enqueue(_ novel: UUID, catchUp: Bool) {
    if let index = queue.firstIndex(where: { $0.novel == novel }) {
      queue[index].catchUp = queue[index].catchUp || catchUp
    } else {
      queue.append(Item(novel: novel, catchUp: catchUp))
    }
    wake?.yield()
  }

  private func next() -> Item? {
    guard let index = queue.firstIndex(where: \.catchUp) ?? queue.indices.first else { return nil }
    return queue.remove(at: index)
  }

  private func drain(_ wakes: AsyncStream<Void>, session: Int) async {
    for await _ in wakes {
      while session == self.session, !Task.isCancelled, let item = next() {
        await perform(item, session: session)
      }
    }
  }

  private func perform(_ item: Item, session: Int) async {
    var pending = item
    do throws(RetrievalError) {
      if item.catchUp {
        try await work.catchUp(item.novel)
        pending.catchUp = false
      }
      let embedding = try await work.embed(item.novel, Self.embeddingBatch)
      failures[item.novel] = nil
      let progressed = embedding.embedded + embedding.failed > 0
      if !embedding.isComplete, progressed, session == self.session { enqueue(item.novel, catchUp: false) }
    } catch .cancelled {
      return
    } catch {
      let failed = (failures[item.novel] ?? 0) + 1
      failures[item.novel] = failed
      let delay = min(retryDelay * (1 << min(failed - 1, 16)), Self.maximumRetryDelay)
      let novel = item.novel.uuidString
      Self.logger.error(
        "Retrieval upkeep failed novel=\(novel, privacy: .private(mask: .hash)) code=\(error.code, privacy: .public) attempt=\(failed, privacy: .public)")
      retry(pending, after: delay, session: session)
    }
  }

  /// A change that arrived during the failed unit already waits, sooner than the retry would, so the retry only joins it.
  private func retry(_ item: Item, after delay: Duration, session: Int) {
    guard session == self.session else { return }
    if queue.contains(where: { $0.novel == item.novel }) { return enqueue(item.novel, catchUp: item.catchUp) }
    if let waiting = timers[item.novel] {
      timers[item.novel] = Timer(token: waiting.token, catchUp: waiting.catchUp || item.catchUp, task: waiting.task)
      return
    }
    schedule(item.novel, after: delay, catchUp: item.catchUp, session: session)
  }

  private static func code(of error: any Error) -> String {
    (error as? any ShadowError)?.code ?? String(describing: type(of: error))
  }
}
