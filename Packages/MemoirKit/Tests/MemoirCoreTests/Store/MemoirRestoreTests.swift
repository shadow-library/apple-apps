import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("MemoirRestore", TestTimeLimit.standard)
struct MemoirRestoreTests {
  private static let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
  private static let now = Date(timeIntervalSince1970: 1_795_000_000)
  private static let image = Data((0..<4096).map { UInt8($0 % 251) })

  @Test("should restore every store, revision, receipt image and weekly review exactly, and replay the same hero")
  func shouldRestoreExactly() async throws {
    let world = try RestoreWorld()
    defer { world.remove() }
    let source = try world.open("Source")
    let fill = try await Self.fill(source)
    let contents = try await Self.contents(of: source, imagesIn: world.root)
    let target = try world.open("Target")

    try await MemoirRestore.restore(contents, into: target.stores)
    try await target.reconciler.refresh(target.stores.main)

    #expect(try await Self.entities(of: target.stores) == Self.entities(of: source.stores))
    let journal = try await Self.journal(fill.journal, in: target.stores)
    let original = try await Self.journal(fill.journal, in: source.stores)
    #expect(journal.revisions.count == 3 && journal.headRevision == original.headRevision)
    let restoredImage = try #require(try await VaultBlobs(store: target.stores.main).localURL(of: fill.blob))
    #expect(try Data(contentsOf: restoredImage) == Self.image)
    #expect(try await VaultBlobs(store: target.stores.main).status(of: fill.blob) == .waitingToUpload)
    #expect(try await Self.reviews(target.stores) == Self.reviews(source.stores))
    #expect(try await target.stores.main.load(HeroDeck.self, HeroDeckQuery()) == source.stores.main.load(HeroDeck.self, HeroDeckQuery()))
    let today = try IssueClock(timeZone: Self.zone).localDate(at: Int64(Self.now.timeIntervalSince1970 * 1000))
    #expect(try await target.stores.main.load(TodayBoard.self, TodayBoardQuery(date: today)) == source.stores.main.load(TodayBoard.self, TodayBoardQuery(date: today)))
    for kind in MemoirStoreKind.allCases {
      #expect(try await !target.stores.store(kind).pendingChanges(limit: 1).isEmpty, "the \(kind) store's data waits for upload")
    }
  }

  @Test("should refuse a vault that holds data in any store and change nothing")
  func shouldRefuseAVaultWithData() async throws {
    let world = try RestoreWorld()
    defer { world.remove() }
    let source = try world.open("Source")
    _ = try await Self.fill(source)
    let contents = try await Self.contents(of: source, imagesIn: world.root)
    let target = try world.open("Target")
    _ = try await QuickLogWriter(stores: target.stores, issuer: Self.issuer).saveWeight(try #require(DecimalText("70.5")), on: LocalDate(isoString: "2026-11-20")!)
    let before = try await Self.entities(of: target.stores)

    let error = await #expect(throws: MemoirRestoreError.self) { try await MemoirRestore.restore(contents, into: target.stores) }
    guard case .vaultNotEmpty? = error else { throw RestoreTestFailure("expected vaultNotEmpty, got \(String(describing: error))") }

    #expect(try await Self.entities(of: target.stores) == before)
    #expect(try await !MemoirRestore.isEmpty(target.stores))
  }

  @Test("should refuse a newer registry, a missing store, a kind in the wrong store and a receipt image no record names, before writing anything")
  func shouldRefuseBeforeWriting() async throws {
    let world = try RestoreWorld()
    defer { world.remove() }
    let source = try world.open("Source")
    let fill = try await Self.fill(source)
    let contents = try await Self.contents(of: source, imagesIn: world.root)
    let stray = try #require(BlobID(String(repeating: "ef", count: 32)))
    let weight = try #require(contents.stores[.restricted]?.entities.first { $0.ref.kind == MemoirKind.weight.entityKind })
    let cases: [(String, MemoirRestoreContents, (MemoirRestoreError) -> Bool)] = [
      (
        "newer registry", Self.replacing(.main, in: contents) { MemoirRestoreContents.Store(registryVersion: MemoirSchema.mainVersion + 1, entities: $0.entities) },
        { if case .registryTooNew(.main, _, _) = $0 { true } else { false } }
      ),
      (
        "registry zero", Self.replacing(.activity, in: contents) { MemoirRestoreContents.Store(registryVersion: 0, entities: $0.entities) },
        { if case .registryUnknown(.activity, 0) = $0 { true } else { false } }
      ),
      (
        "missing store", MemoirRestoreContents(stores: contents.stores.filter { $0.key != .restricted }, receiptImages: [], weeklyReviews: [:]),
        { if case .storeMissing(.restricted) = $0 { true } else { false } }
      ),
      (
        "wrong store", Self.replacing(.main, in: contents) { MemoirRestoreContents.Store(registryVersion: $0.registryVersion, entities: $0.entities + [weight]) },
        { if case .refused = $0 { true } else { false } }
      ),
      (
        "unnamed image",
        MemoirRestoreContents(
          stores: contents.stores, receiptImages: contents.receiptImages + [.init(blob: stray, file: contents.receiptImages[0].file)], weeklyReviews: [:]),
        { if case .receipt = $0 { true } else { false } }
      ),
      (
        "image of another size",
        MemoirRestoreContents(stores: contents.stores, receiptImages: [.init(blob: fill.blob, file: try Self.file(Data([1, 2]), in: world.root))], weeklyReviews: [:]),
        { if case .receipt = $0 { true } else { false } }
      ),
    ]
    let target = try world.open("Target")
    for (name, refused, matches) in cases {
      let error = await #expect(throws: MemoirRestoreError.self, "\(name) is refused") { try await MemoirRestore.restore(refused, into: target.stores) }
      #expect(error.map(matches) == true, "\(name) is refused for its reason, not \(String(describing: error))")
      #expect(try await MemoirRestore.isEmpty(target.stores), "\(name) wrote nothing")
    }
    #expect(try Self.blobFiles(target).isEmpty)
  }

  @Test("should leave the main and health stores empty and keep no receipt image when the activity store's import fails")
  func shouldRollBackWhenTheLastStoreFails() async throws {
    let world = try RestoreWorld()
    defer { world.remove() }
    let source = try world.open("Source")
    _ = try await Self.fill(source)
    let contents = try await Self.contents(of: source, imagesIn: world.root)
    let oversized = Self.replacing(.activity, in: contents) { store in
      let entities = store.entities.map { entity -> ImportedEntity in
        guard case .record(let ref, var fields) = entity, ref.kind == MemoirKind.activityMetricDay.entityKind else { return entity }
        fields[MetricDayField.entry.rawValue] = .object(["value": .string(String(repeating: "9", count: VaultStore.maximumChangeBytes))])
        return .record(ref, fields: fields)
      }
      return MemoirRestoreContents.Store(registryVersion: store.registryVersion, entities: entities)
    }
    #expect(oversized.stores[.activity]?.entities != contents.stores[.activity]?.entities, "an activity metric day is made too large")
    try MemoirRestore.check(oversized)
    let target = try world.open("Target")

    let error = await #expect(throws: MemoirRestoreError.self) { try await MemoirRestore.restore(oversized, into: target.stores) }
    guard case .store(.changeTooLarge)? = error else { throw RestoreTestFailure("expected the activity store to fail, got \(String(describing: error))") }

    #expect(try await MemoirRestore.isEmpty(target.stores))
    for kind in MemoirStoreKind.allCases { #expect(try await target.stores.store(kind).pendingChanges(limit: 1).isEmpty) }
    #expect(try await Self.reviews(target.stores).isEmpty)
    #expect(try Self.blobFiles(target).isEmpty, "the staged receipt image is removed")
  }

  @Test("should leave a marker that names the vault half restored when main's commit fails after the other stores committed, and refuse to restore again")
  func shouldMarkAnUnfinishedRestore() async throws {
    let world = try RestoreWorld()
    defer { world.remove() }
    let source = try world.open("Source")
    _ = try await Self.fill(source)
    let contents = try await Self.contents(of: source, imagesIn: world.root)
    let target = try world.open("Target")

    let error = await #expect(throws: MemoirRestoreError.self) {
      try await MemoirRestore.restore(contents, into: target.stores) { database in
        try database.execute(
          sql: """
            CREATE TABLE failing_parent (id INTEGER PRIMARY KEY);
            CREATE TABLE failing_child (parent INTEGER REFERENCES failing_parent(id) DEFERRABLE INITIALLY DEFERRED);
            INSERT INTO failing_child (parent) VALUES (1);
            """)
      }
    }

    guard case .unfinished? = error else { throw RestoreTestFailure("expected an unfinished restore, got \(String(describing: error))") }
    #expect(try await !target.stores.main.read { transaction in try transaction.holdsEntities(ofKinds: MemoirRestore.dataKinds(of: .main)) })
    #expect(try await target.stores.restricted.read { transaction in try transaction.holdsEntities(ofKinds: MemoirRestore.dataKinds(of: .restricted)) })
    #expect(try await MemoirRestore.isUnfinished(target.stores))
    #expect(try await !MemoirRestore.isEmpty(target.stores))
    #expect(try Self.blobFiles(target).isEmpty, "the staged receipt image is removed")
    let again = await #expect(throws: MemoirRestoreError.self) { try await MemoirRestore.restore(contents, into: target.stores) }
    guard case .unfinished? = again else { throw RestoreTestFailure("expected an unfinished restore again, got \(String(describing: again))") }
  }

  @Test("should clear the marker when a restore fails before any store commits, and restore on the next try")
  func shouldClearTheMarkerAfterARolledBackFailure() async throws {
    let world = try RestoreWorld()
    defer { world.remove() }
    let source = try world.open("Source")
    _ = try await Self.fill(source)
    let contents = try await Self.contents(of: source, imagesIn: world.root)
    let target = try world.open("Target")

    await #expect(throws: MemoirRestoreError.self) {
      try await MemoirRestore.restore(contents, into: target.stores) { _ in throw RestoreTestFailure("refused before the other stores ran") }
    }

    #expect(try await MemoirRestore.isEmpty(target.stores))
    #expect(try await !MemoirRestore.isUnfinished(target.stores))
    #expect(try await !target.stores.main.read { transaction in try transaction.database.tableExists(RestorePending.table) })
    try await MemoirRestore.restore(contents, into: target.stores)
    #expect(try await !MemoirRestore.isEmpty(target.stores))
    #expect(try await !MemoirRestore.isUnfinished(target.stores))
    #expect(try await !target.stores.main.read { transaction in try transaction.database.tableExists(RestorePending.table) })
  }

  @Test("should take a marker beside data in the main store alone as stale, clear it and refuse the restore as a vault with data")
  func shouldClearAStaleMarker() async throws {
    let world = try RestoreWorld()
    defer { world.remove() }
    let source = try world.open("Source")
    _ = try await Self.fill(source)
    let contents = try await Self.contents(of: source, imagesIn: world.root)
    let target = try world.open("Target")
    let category = try #require(CategoryKey("food"))
    let expense = ExpenseRecord(
      id: UUID(), amountMinor: 500, currency: try #require(CurrencyCode("EUR")), occurredOn: LocalDate(isoString: "2026-11-20")!, category: category, loggedAtMillis: 1)
    try await target.stores.main.write { transaction in
      try RestorePending.mark(atMillis: 1, in: transaction.database)
      _ = try expense.create(in: &transaction)
    }

    #expect(try await !MemoirRestore.isUnfinished(target.stores))
    #expect(try await target.stores.main.read { transaction in try transaction.database.tableExists(RestorePending.table) }, "reading leaves the marker")

    try await MemoirRestore.clearStaleMarker(target.stores)
    #expect(try await !target.stores.main.read { transaction in try transaction.database.tableExists(RestorePending.table) }, "the stale marker is cleared")
    let error = await #expect(throws: MemoirRestoreError.self) { try await MemoirRestore.restore(contents, into: target.stores) }
    guard case .vaultNotEmpty? = error else { throw RestoreTestFailure("expected vaultNotEmpty, got \(String(describing: error))") }
  }

  @Test("should refuse a command whose ruleset this build lacks as newer, and one it cannot read as refused")
  func shouldCheckCommands() async throws {
    let world = try RestoreWorld()
    defer { world.remove() }
    let source = try world.open("Source")
    _ = try await Self.fill(source)
    let contents = try await Self.contents(of: source, imagesIn: world.root)
    let newer = Self.changingFirstCommand(in: contents) { $0[CommandMember.rulesetVersion.rawValue] = .int(Int64(Ruleset.current.version + 1)) }
    let unreadable = Self.changingFirstCommand(in: contents) { $0[CommandMember.payload.rawValue] = .object(["unknown_member": "x"]) }

    let tooNew = #expect(throws: MemoirRestoreError.self) { try MemoirRestore.check(newer) }
    guard case .rulesetTooNew? = tooNew else { throw RestoreTestFailure("expected a newer ruleset, got \(String(describing: tooNew))") }
    let refused = #expect(throws: MemoirRestoreError.self) { try MemoirRestore.check(unreadable) }
    guard case .refused? = refused else { throw RestoreTestFailure("expected a refusal, got \(String(describing: refused))") }
    try MemoirRestore.check(contents)
  }

  private static func changingFirstCommand(in contents: MemoirRestoreContents, _ change: (inout [String: JSONValue]) -> Void) -> MemoirRestoreContents {
    replacing(.main, in: contents) { store in
      var changed = false
      let entities = store.entities.map { entity -> ImportedEntity in
        guard !changed, case .appended(let ref, var item) = entity, ref.kind == MemoirKind.command.entityKind else { return entity }
        changed = true
        change(&item)
        return .appended(ref, item: item)
      }
      return MemoirRestoreContents.Store(registryVersion: store.registryVersion, entities: entities)
    }
  }

  private static var issuer: CommandIssuerSource {
    let issuer = CommandIssuer(clock: IssueClock(timeZone: zone), wallClock: { now })
    return CommandIssuerSource { _ in issuer }
  }

  private struct Fill {
    let journal: UUID
    let blob: BlobID
  }

  private static func fill(_ vault: RestoreWorld.Opened) async throws -> Fill {
    let stores = vault.stores
    try await MemoirDemo.seed(stores, now: now, zone: zone, currency: try #require(CurrencyCode("EUR")))
    let day = try IssueClock(timeZone: zone).localDate(at: Int64(now.timeIntervalSince1970 * 1000))
    try await MetricCatalog(stores: stores, issuer: issuer).register(try #require(DecimalText("98765")), for: BuiltinMetric.steps.reference, on: day)
    _ = try await QuickLogWriter(stores: stores, issuer: issuer).saveWeight(try #require(DecimalText("81.2345")), on: day)
    let blob = try await VaultBlobs(store: stores.main).put(image)
    let journal = UUID()
    let receipt = ReceiptRecord(id: UUID(), blob: try #require(BlobName(blob.description)), contentType: "image/jpeg", byteCount: image.count)
    try await stores.main.write { transaction in
      _ = try receipt.create(in: &transaction)
      _ = try JournalEntryRecord(id: journal, date: day, text: "First words.", mood: 3, loggedAtMillis: 1).create(in: &transaction)
    }
    for text in ["Second words.", "Third words."] {
      try await stores.main.write { transaction in _ = try JournalEntryRecord.edit(JournalEntryRecord.ref(journal), in: &transaction) { $0.text = text } }
    }
    try await WeeklyReviewAnswers.save("Slept before midnight", for: .better, week: day, in: stores)
    try await WeeklyReviewAnswers.complete(week: day, atMillis: 7, in: stores)
    try await vault.reconciler.refresh(stores.main)
    return Fill(journal: journal, blob: blob)
  }

  private static func contents(of vault: RestoreWorld.Opened, imagesIn root: URL) async throws -> MemoirRestoreContents {
    var stores = [MemoirStoreKind: MemoirRestoreContents.Store]()
    for (kind, entities) in try await entities(of: vault.stores) {
      stores[kind] = MemoirRestoreContents.Store(registryVersion: kind.registry.version, entities: entities)
    }
    var images = [MemoirRestoreContents.ReceiptImage]()
    let receipts = try await vault.stores.main.read { transaction in try ReceiptRecord.listing(in: transaction) }
    for receipt in receipts.entries.map(\.record) {
      let blob = try #require(BlobID(receipt.blob.name))
      let held = try #require(try await VaultBlobs(store: vault.stores.main).localURL(of: blob))
      images.append(.init(blob: blob, file: try file(try Data(contentsOf: held), in: root)))
    }
    return MemoirRestoreContents(stores: stores, receiptImages: images, weeklyReviews: try await reviews(vault.stores))
  }

  private static func replacing(
    _ kind: MemoirStoreKind, in contents: MemoirRestoreContents, _ change: (MemoirRestoreContents.Store) throws -> MemoirRestoreContents.Store
  ) rethrows -> MemoirRestoreContents {
    var stores = contents.stores
    if let store = stores[kind] { stores[kind] = try change(store) }
    return MemoirRestoreContents(stores: stores, receiptImages: contents.receiptImages, weeklyReviews: contents.weeklyReviews)
  }

  /// Every entity of a store's data kinds as stored, revisions with their creation clocks and appended items in the order of their clocks, which is
  /// what an export keeps.
  private static func entities(of stores: MemoirStores) async throws -> [MemoirStoreKind: [ImportedEntity]] {
    var all = [MemoirStoreKind: [ImportedEntity]]()
    for kind in MemoirStoreKind.allCases {
      let kinds = MemoirRestore.dataKinds(of: kind).sorted()
      all[kind] = try await stores.store(kind).read { transaction in
        try kinds.flatMap { entityKind in
          try transaction.states(ofKind: entityKind).sorted { first, second in
            guard case .appended(let one) = first.state, case .appended(let other) = second.state, one.clock != other.clock else { return first.ref < second.ref }
            return one.clock < other.clock
          }
          .compactMap { ref, state -> ImportedEntity? in
            switch state {
            case .purged: return nil
            case .record(let record): return .record(ref, fields: record.fields.reduce(into: [:]) { $0[$1.key.value] = $1.value.value })
            case .appended(let appended): return .appended(ref, item: appended.item)
            case .revisioned(let document):
              let revisions = document.revisions.map { id, item in
                ImportedRevision(id: id.value, parent: item.parent, body: item.body, generation: item.generation, created: item.created)
              }
              return .revisioned(
                ref, fields: document.fields.reduce(into: [:]) { $0[$1.key.value] = $1.value.value }, head: document.headRevision,
                revisions: revisions.sorted { ($0.generation, $0.id) < ($1.generation, $1.id) })
            }
          }
        }
      }
    }
    return all
  }

  private static func journal(_ id: UUID, in stores: MemoirStores) async throws -> RevisionedState {
    let state = try await stores.main.read { transaction in try transaction.state(of: JournalEntryRecord.ref(id)) }
    guard case .revisioned(let document)? = state else { throw RestoreTestFailure("the journal entry is not revisioned") }
    return document
  }

  private static func reviews(_ stores: MemoirStores) async throws -> [LocalDate: ReviewAnswers] {
    try await stores.main.read { transaction in try WeeklyReviewAnswers.weeks(in: transaction) }
  }

  private static func file(_ data: Data, in root: URL) throws -> URL {
    let url = root.appending(path: "image-\(UUID().uuidString)")
    try data.write(to: url)
    return url
  }

  private static func blobFiles(_ vault: RestoreWorld.Opened) throws -> [String] {
    guard let directory = vault.stores.main.blobDirectory, FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
  }
}

private struct RestoreWorld {
  struct Opened {
    let stores: MemoirStores
    let reconciler: MemoirReconciler
  }

  let root: URL

  init() throws {
    root = try MemoirStoreFixture.temporaryDirectory()
  }

  func open(_ name: String) throws -> Opened {
    let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    let reconciler = try MemoirReconciler(appVersion: "1", now: { now }, deviceZone: { zone })
    let vault = try MemoirVault(directory: root.appending(path: "Vaults", directoryHint: .isDirectory), name: name)
    return Opened(stores: try MemoirStores.open(in: vault, wallClock: { now }, projection: reconciler), reconciler: reconciler)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private struct RestoreTestFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
