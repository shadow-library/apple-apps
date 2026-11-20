import Foundation
import ShadowSync

/// Key → Drive file index of one vault, kept from the changes feed. Drive never reuses a file id, so an id this device deleted is ignored until the feed reports it removed,
/// and a feed state older than the version this device wrote is ignored. The index is saved when other devices changed it; a saved token that lags only replays
/// changes the version guard already absorbs.
actor GoogleDriveIndex {
  private typealias Outcome = Result<Void, StorageError>

  private let client: GoogleDriveClient
  private let store: any GoogleDriveStateStore
  private let tuning: GoogleDriveTuning
  private var loaded = false
  private var loading: Task<Outcome, Never>?
  private var catchingUp: Task<Outcome, Never>?
  private var pageToken: String?
  private var files: [String: GoogleDriveIndexedFile] = [:]
  private var idsByKey: [ObjectKey: Set<String>] = [:]
  private var removed: [String: Int] = [:]
  private var generation = 0
  private var writtenDuringCatchUp: [String: GoogleDriveIndexedFile] = [:]
  private var settleAt: Date?
  private var tokenFromRebuild = false
  private var rebuildBlockedUntil: Date?
  private var rebuildBackoff: TimeInterval?
  private var feedRemovals: Set<String> = []
  private var dirty = false
  private var savedToken: String?
  private var savedAt: Date?

  init(client: GoogleDriveClient, store: any GoogleDriveStateStore, tuning: GoogleDriveTuning) {
    self.client = client
    self.store = store
    self.tuning = tuning
  }

  func candidates(of key: ObjectKey) async throws(StorageError) -> [GoogleDriveIndexedFile] {
    try await loadIfNeeded()
    return (idsByKey[key] ?? []).compactMap { files[$0] }.sorted { $0.wins(over: $1) }
  }

  func winner(of key: ObjectKey) async throws(StorageError) -> GoogleDriveIndexedFile? {
    try await candidates(of: key).first
  }

  func page(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    if cursor == nil || pageToken == nil { try await catchUp() }
    let keys = idsByKey.keys.filter { key in key.hasPrefix(prefix) && cursor.map { $0.token.utf8.lexicographicallyPrecedes(key.rawValue.utf8) } ?? true }.sorted()
    let chosen = keys.prefix(tuning.listPageSize)
    let objects = chosen.compactMap { key in winnerInIndex(of: key).map { StorageObject(key: key, size: $0.size) } }
    let next = keys.count > chosen.count ? chosen.last.map { ListCursor(token: $0.rawValue) } : nil
    return ListPage(objects: objects, next: next)
  }

  func record(_ file: GoogleDriveIndexedFile) {
    upsert(file)
    if catchingUp != nil { writtenDuringCatchUp[file.id] = file }
  }

  func forget(_ id: String) {
    generation += 1
    removed[id] = generation
    writtenDuringCatchUp[id] = nil
    drop(id)
  }

  func catchUp() async throws(StorageError) {
    try await loadIfNeeded()
    if let catchingUp { return try await catchingUp.value.get() }
    let task = Task { await self.runCatchUp() }
    catchingUp = task
    try await task.value.get()
  }

  private func loadIfNeeded() async throws(StorageError) {
    guard !loaded else { return }
    let task = loading ?? Task { await self.load() }
    loading = task
    try await task.value.get()
  }

  private func load() async -> Outcome {
    defer { loading = nil }
    do {
      if let state = try await store.load(), state.format == GoogleDriveIndexState.currentFormat, state.vault == client.vault {
        pageToken = state.pageToken
        savedToken = state.pageToken
        settleAt = state.settleAt
        tokenFromRebuild = state.tokenFromRebuild
        rebuildBlockedUntil = state.rebuildBlockedUntil
        rebuildBackoff = state.rebuildBackoff
        for file in state.files { upsert(file) }
        removed = Dictionary(state.removed.map { ($0, 0) }) { first, _ in first }
      }
      loaded = true
      return .success(())
    } catch {
      return .failure(error)
    }
  }

  private func runCatchUp() async -> Outcome {
    defer {
      catchingUp = nil
      writtenDuringCatchUp = [:]
    }
    do throws(StorageError) {
      if pageToken == nil { try await rebuild() } else { try await followFeed() }
      if let settleAt, tuning.now() >= settleAt { try await settle() }
      if dirty || tokenSaveIsDue() { try await persist() }
      return .success(())
    } catch {
      if dirty { try? await persist() }
      return .failure(error)
    }
  }

  private func persist() async throws(StorageError) {
    let snapshot = snapshot()
    try await store.save(snapshot)
    dirty = false
    savedToken = snapshot.pageToken
    savedAt = tuning.now()
  }

  private func tokenSaveIsDue() -> Bool {
    guard pageToken != savedToken else { return false }
    guard let savedAt else { return true }
    return tuning.now().timeIntervalSince(savedAt) >= tuning.tokenSaveInterval
  }

  private func followFeed() async throws(StorageError) {
    for _ in 0..<tuning.catchUpPages {
      guard let current = pageToken else { return }
      switch try await client.changes(after: current) {
      case .tokenRejected:
        if tokenFromRebuild { try holdRebuild() }
        return try await rebuild()
      case .page(let page):
        if tokenFromRebuild || rebuildBackoff != nil {
          tokenFromRebuild = false
          rebuildBackoff = nil
          rebuildBlockedUntil = nil
          dirty = true
        }
        apply(page.changes)
        if let next = page.nextPageToken {
          pageToken = next
          continue
        }
        guard let start = page.newStartPageToken else { throw GoogleDriveFailure.malformed("change page") }
        pageToken = start
        return
      }
    }
  }

  /// A token a rebuild just took was rejected before any page succeeded, so rebuilding at once would enumerate on every catch-up. One more rebuild is allowed after
  /// a backoff that doubles up to a day, and a successful page resets it.
  private func holdRebuild() throws(StorageError) {
    let now = tuning.now()
    if let rebuildBlockedUntil {
      guard now >= rebuildBlockedUntil else { throw Self.rebuildHeld }
      self.rebuildBlockedUntil = nil
      return
    }
    let backoff = rebuildBackoff.map { min($0 * 2, tuning.maxRebuildBackoff) } ?? tuning.rebuildBackoff
    rebuildBackoff = backoff
    rebuildBlockedUntil = now.addingTimeInterval(backoff)
    dirty = true
    throw Self.rebuildHeld
  }

  private static let rebuildHeld = StorageError.unavailable("Google Drive keeps rejecting new change tokens; the index is rebuilt again later.")

  /// The start token is taken before the enumeration, so a change made while it runs is replayed by the feed rather than lost.
  /// Its token stays marked until a feed page succeeds, so a feed that rejects every token fails instead of enumerating on every catch-up.
  /// A file created just before the token that search does not show yet is found by the settling enumeration that follows.
  private func rebuild() async throws(StorageError) {
    let started = generation
    let start = try await client.startPageToken()
    let found = try await enumerate()
    removed = removed.filter { found[$0.key] != nil || $0.value > started }
    files = [:]
    idsByKey = [:]
    for file in found.values where removed[file.id] == nil { upsert(file) }
    for file in writtenDuringCatchUp.values where removed[file.id] == nil { upsert(file) }
    pageToken = start
    tokenFromRebuild = true
    settleAt = tuning.now().addingTimeInterval(tuning.settleDelay)
    dirty = true
  }

  /// Adds what search shows and the index lacks, and removes nothing: the feed has reported every change since the start token.
  private func settle() async throws(StorageError) {
    let started = generation
    let found = try await enumerate()
    for file in found.values where removed[file.id] == nil { upsert(file) }
    removed = removed.filter { found[$0.key] != nil || $0.value > started }
    for id in feedRemovals { removed[id] = nil }
    feedRemovals = []
    settleAt = nil
    dirty = true
  }

  private func enumerate() async throws(StorageError) -> [String: GoogleDriveIndexedFile] {
    var found: [String: GoogleDriveIndexedFile] = [:]
    var next: String?
    var pages = 0
    repeat {
      pages += 1
      guard pages <= tuning.enumerationPages else { throw .unavailable("The Google Drive vault has more files than one enumeration reads.") }
      let page = try await client.files(after: next)
      for resource in page.files {
        guard let file = client.indexed(resource) else { continue }
        found[file.id] = file
      }
      next = page.nextPageToken
    } while next != nil
    return found
  }

  private func apply(_ changes: [DriveChange]) {
    for change in changes where change.changeType ?? "file" == "file" {
      guard let id = change.fileId ?? change.file?.id else { continue }
      guard change.removed != true, let file = change.file.flatMap(client.indexed) else {
        remember(removalOf: id)
        if drop(id) { dirty = true }
        continue
      }
      if removed[id] == nil && upsert(file) { dirty = true }
    }
  }

  /// Until the settling enumeration, a removal is remembered so that a search still showing the file cannot bring it back.
  private func remember(removalOf id: String) {
    guard settleAt != nil else {
      removed[id] = nil
      return
    }
    generation += 1
    removed[id] = generation
    feedRemovals.insert(id)
  }

  @discardableResult
  private func upsert(_ file: GoogleDriveIndexedFile) -> Bool {
    if let existing = files[file.id] {
      guard existing.version <= file.version, existing != file else { return false }
      if existing.key != file.key { unlink(existing) }
    }
    files[file.id] = file
    idsByKey[file.key, default: []].insert(file.id)
    return true
  }

  @discardableResult
  private func drop(_ id: String) -> Bool {
    guard let existing = files.removeValue(forKey: id) else { return false }
    unlink(existing)
    return true
  }

  private func unlink(_ file: GoogleDriveIndexedFile) {
    idsByKey[file.key]?.remove(file.id)
    if idsByKey[file.key]?.isEmpty == true { idsByKey[file.key] = nil }
  }

  private func winnerInIndex(of key: ObjectKey) -> GoogleDriveIndexedFile? {
    (idsByKey[key] ?? []).compactMap { files[$0] }.min { $0.wins(over: $1) }
  }

  private func snapshot() -> GoogleDriveIndexState {
    GoogleDriveIndexState(
      vault: client.vault, pageToken: pageToken ?? "", files: files.values.sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }, removed: removed.keys.sorted(),
      settleAt: settleAt, tokenFromRebuild: tokenFromRebuild,
      rebuildBlockedUntil: rebuildBlockedUntil, rebuildBackoff: rebuildBackoff)
  }
}
