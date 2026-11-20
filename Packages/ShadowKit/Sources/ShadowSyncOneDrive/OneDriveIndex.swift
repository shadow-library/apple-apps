import Foundation
import ShadowNetworking
import ShadowSync

/// The vault folder's key index, fed only by the delta feed: every entry stands for a file the feed reported, so a listing may lag but never invents.
actor OneDriveIndex {
  private struct Table {
    var byID: [String: OneDriveIndexEntry]
    var idByName: [String: String]

    init(_ entries: [String: OneDriveIndexEntry]) {
      byID = entries
      idByName = Dictionary(entries.values.map { ($0.name, $0.itemID) }) { first, _ in first }
    }

    mutating func upsert(_ entry: OneDriveIndexEntry) {
      if let other = idByName[entry.name], other != entry.itemID { byID[other] = nil }
      remove(entry.itemID)
      byID[entry.itemID] = entry
      idByName[entry.name] = entry.itemID
    }

    mutating func remove(_ itemID: String) {
      guard let entry = byID.removeValue(forKey: itemID) else { return }
      if idByName[entry.name] == itemID { idByName[entry.name] = nil }
    }
  }

  private enum PageOutcome {
    case applied
    case folderGone
  }

  private static let resyncLimit = 3
  private static let refusedFeedStatuses: Set<Int> = [400, 403, 501, 505]

  private let client: GraphClient
  private let paths: OneDrivePaths
  private let store: any OneDriveStateStore
  private let vaultFolder: VaultFolderName
  private let maxPages: Int
  private var state: OneDriveIndexState?
  private var saved: OneDriveIndexState?
  private var sorted: [OneDriveIndexEntry]?
  private var running: Task<Result<Void, StorageError>, Never>?

  init(client: GraphClient, paths: OneDrivePaths, store: any OneDriveStateStore, vaultFolder: VaultFolderName, maxPages: Int) {
    self.client = client
    self.paths = paths
    self.store = store
    self.vaultFolder = vaultFolder
    self.maxPages = maxPages
  }

  /// The entries in ascending key order, after catching up with the feed when `catchUp` is set.
  func entries(catchUp: Bool) async throws(StorageError) -> [OneDriveIndexEntry] {
    if catchUp { try await self.catchUp() }
    let state = try await loaded()
    if let sorted { return sorted }
    let ordered = state.entries.values.sorted { $0.key < $1.key }
    sorted = ordered
    return ordered
  }

  func catchUp() async throws(StorageError) {
    if let running { return try await running.value.get() }
    let task = Task { await self.runCatchUp() }
    running = task
    let outcome = await task.value
    running = nil
    try outcome.get()
  }

  private func loaded() async throws(StorageError) -> OneDriveIndexState {
    if let state { return state }
    let stored = try await store.load()
    let usable = stored.flatMap { $0.formatVersion == OneDriveIndexState.formatVersion && $0.vaultFolder == vaultFolder.rawValue ? $0 : nil }
    let initial = usable ?? OneDriveIndexState(vaultFolder: vaultFolder)
    if state == nil {
      state = initial
      saved = usable
    }
    return state ?? initial
  }

  private func runCatchUp() async -> Result<Void, StorageError> {
    do throws(StorageError) {
      try await advance()
    } catch {
      try? await persist()
      return .failure(error)
    }
    do throws(StorageError) {
      try await persist()
      return .success(())
    } catch {
      return .failure(error)
    }
  }

  private func advance() async throws(StorageError) {
    var current = try await loaded()
    var pages = 0
    var resyncs = 0
    var resets = 0
    var recovered = false
    var resolvedHere = false
    while pages < maxPages {
      resolvedHere = resolvedHere || current.folderID == nil
      guard let folderID = try await resolveFolder(&current) else { return commit(current) }
      let link = current.position.map(Self.link) ?? client.url(OneDrivePaths.delta(folderID: folderID))
      guard let link else { throw .underlying("the OneDrive delta address cannot be built") }
      if current.position == nil { current.replacement = [:] }
      let response = try await client.authorized(Self.get(link))
      switch response.status {
      case 200:
        let page = try Self.decodePage(response.body)
        pages += 1
        if try await apply(page.value, folderID: folderID, to: &current) == .folderGone {
          resets += 1
          current = OneDriveIndexState(vaultFolder: vaultFolder)
          commit(current)
          guard resets < 2 else { return }
          continue
        }
        if let next = page.nextLink {
          current.position = .paging(next)
        } else if let delta = page.deltaLink {
          current.position = .caughtUp(delta)
          if let replacement = current.replacement {
            current.entries = replacement
            current.replacement = nil
          }
          return commit(current)
        } else {
          throw .underlying("a OneDrive delta page carried neither a next nor a delta link")
        }
        commit(current)
      case 410:
        resyncs += 1
        guard resyncs <= Self.resyncLimit else { throw .unavailable("OneDrive kept asking for a resync") }
        let restart = response.headers["location"].flatMap(URL.init(string:)) ?? client.url(OneDrivePaths.delta(folderID: folderID))
        guard let restart else { throw .underlying("the OneDrive delta address cannot be built") }
        current.position = .paging(restart)
        current.replacement = [:]
        commit(current)
      case 404:
        resets += 1
        current = OneDriveIndexState(vaultFolder: vaultFolder)
        commit(current)
        guard resets < 2 else { return }
      default:
        guard isRefusal(response) else { throw client.failure(response) }
        current.folderID = nil
        current.position = nil
        current.replacement = nil
        commit(current)
        guard !recovered, !resolvedHere else { throw .underlying("OneDrive offers no change feed for the vault folder on this account") }
        recovered = true
      }
    }
  }

  /// A saved link or folder id may have gone bad, so a refusal of one starts over from the folder's path once; work and school drives may
  /// refuse delta below the drive root outright, which neither retrying nor signing in again can change.
  private func isRefusal(_ response: GraphResponse) -> Bool {
    switch client.failure(response) {
    case .rateLimited, .quotaExceeded, .unavailable: false
    default:
      Self.refusedFeedStatuses.contains(response.status) || response.codes.contains("notSupported") || response.codes.contains("notImplemented")
    }
  }

  private func resolveFolder(_ current: inout OneDriveIndexState) async throws(StorageError) -> String? {
    if let folderID = current.folderID { return folderID }
    guard let url = client.url(paths.folder) else { throw .underlying("the OneDrive vault address cannot be built") }
    let response = try await client.authorized(Self.get(url))
    if response.status == 404 {
      current = OneDriveIndexState(vaultFolder: vaultFolder)
      return nil
    }
    guard response.isSuccess else { throw client.failure(response) }
    guard let item = try? JSONDecoder.shadow().decode(GraphItem.self, from: response.body), item.folder != nil else {
      throw .unavailable("the OneDrive vault path does not name a folder")
    }
    current.folderID = item.id
    current.appFolderID = item.parentReference?.id
    current.position = nil
    current.replacement = [:]
    return item.id
  }

  private func apply(_ items: [GraphItem], folderID: String, to current: inout OneDriveIndexState) async throws(StorageError) -> PageOutcome {
    var table = Table(current.replacement ?? current.entries)
    let known = Table(current.entries)
    for item in items {
      if item.id == folderID {
        guard item.deleted == nil, item.name.map(isVaultFolderName) ?? true, isUnderAppFolder(item, current.appFolderID) else { return .folderGone }
        continue
      }
      guard item.deleted == nil, item.file != nil, item.parentReference?.id == folderID, let name = item.name, let decoded = OneDriveName.decode(name) else {
        table.remove(item.id)
        continue
      }
      guard let entry = try await entry(for: item, name: name, decoded: decoded, known: [table, known]) else {
        table.remove(item.id)
        continue
      }
      table.upsert(entry)
    }
    if current.replacement != nil { current.replacement = table.byID } else { current.entries = table.byID }
    return .applied
  }

  private func entry(for item: GraphItem, name: String, decoded: OneDriveName.Decoded, known: [Table]) async throws(StorageError) -> OneDriveIndexEntry? {
    let size = item.size ?? 0
    switch decoded {
    case .key(let key):
      return OneDriveIndexEntry(itemID: item.id, name: name, key: key, size: size, eTag: item.eTag, cTag: item.cTag)
    case .overflow:
      var resolved = known.lazy.compactMap { table in table.idByName[name].flatMap { table.byID[$0]?.key } }.first
      if resolved == nil { resolved = try await overflowKey(itemID: item.id, name: name) }
      guard let key = resolved else { return nil }
      let dataSize = size - OneDriveKeyHeader.encode(key).count
      guard dataSize >= 0 else { return nil }
      return OneDriveIndexEntry(itemID: item.id, name: name, key: key, size: dataSize, eTag: item.eTag, cTag: item.cTag)
    }
  }

  private func overflowKey(itemID: String, name: String) async throws(StorageError) -> ObjectKey? {
    guard let url = client.url(OneDrivePaths.content(itemID: itemID)) else { throw .underlying("the OneDrive content address cannot be built") }
    let head = try await OneDriveDownload.fetch(url, client: client, prefix: OneDriveKeyHeader.maximumLength)
    return head.flatMap { OneDriveKeyHeader.decode($0, name: name)?.key }
  }

  private func isUnderAppFolder(_ item: GraphItem, _ appFolderID: String?) -> Bool {
    guard let parent = item.parentReference?.id, let appFolderID else { return true }
    return parent == appFolderID
  }

  private func isVaultFolderName(_ name: String) -> Bool {
    name.compare(vaultFolder.rawValue, options: [.caseInsensitive]) == .orderedSame
  }

  private func commit(_ next: OneDriveIndexState) {
    if state?.entries != next.entries { sorted = nil }
    state = next
  }

  private func persist() async throws(StorageError) {
    guard let state, state != saved else { return }
    try await store.save(state)
    saved = state
  }

  private static func link(_ position: OneDriveFeedPosition) -> URL {
    switch position {
    case .paging(let url), .caughtUp(let url): url
    }
  }

  private static func get(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private static func decodePage(_ data: Data) throws(StorageError) -> GraphDeltaPage {
    do {
      return try JSONDecoder.shadow().decode(GraphDeltaPage.self, from: data)
    } catch {
      throw .unavailable("a OneDrive delta page could not be read")
    }
  }
}
