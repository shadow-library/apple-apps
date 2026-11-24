import Compression
import Foundation
import GRDB
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import Testing

@testable import Memoir

@MainActor
@Suite("Restore from an export", TestTimeLimit.standard)
struct RestoreTests {
  @Test("should restore an export into an empty vault so that exporting it again gives the same file, and replay the same hero")
  func shouldRoundTrip() async throws {
    let source = try DataWorld()
    defer { source.remove() }
    let opened = try await source.open()
    try await RestoreWorld.fill(opened, world: source)
    let archive = try await MemoirExporter.archive(of: opened.stores, at: Date(), appVersion: "1", into: source.exports)
    let target = try DataWorld()
    defer { target.remove() }
    let restored = try await target.open()
    let model = RestoreWorld.model(restored, in: target)
    let zip = try ZipArchive(contentsOf: archive.url, maximumBytes: MemoirImporter.maximumArchiveBytes, maximumEntries: 100)
    #expect(zip.entries.values.contains { $0.method == 8 }, "the system's archive deflates, so the reader inflates")

    await model.refresh()
    #expect(model.isOffered)
    await model.picked(.success(archive.url))
    guard case .confirming(let preview) = model.stage else { throw RestoreTestFailure("expected a confirmation, got \(model.stage)") }
    #expect(preview.receiptImages == 1 && preview.receiptsWithoutImage == 1 && preview.weeklyReviews == 1 && preview.appVersion == "1")
    #expect(preview.vaultContents.count(.expenses) == 7 && preview.vaultContents.count(.weights) == 1, "the demo's six expenses and the filled one")
    #expect(try await model.confirm())

    #expect(model.stage == .idle && !model.isOffered)
    #expect(!FileManager.default.fileExists(atPath: RestoreWorld.restores(in: target).directory.path(percentEncoded: false)), "the read images are gone")
    let again = try await MemoirExporter.archive(of: restored.stores, at: Date(), appVersion: "1", into: target.exports)
    #expect(try RestoreWorld.normalised(RestoreWorld.manifest(of: again.url)) == RestoreWorld.normalised(RestoreWorld.manifest(of: archive.url)))
    #expect(again.missingImages == 1)
    #expect(try await restored.stores.main.load(HeroDeck.self, HeroDeckQuery()) == opened.stores.main.load(HeroDeck.self, HeroDeckQuery()))
    #expect(try await !restored.stores.main.read { transaction in try OnboardingStanding.isNeeded(in: transaction) }, "onboarding gives way")
  }

  @Test("should send the restored data through sync as this device's changes")
  func shouldUploadTheRestoredData() async throws {
    let source = try DataWorld()
    defer { source.remove() }
    let opened = try await source.open()
    try await RestoreWorld.fill(opened, world: source)
    let archive = try await MemoirExporter.archive(of: opened.stores, at: Date(), appVersion: "1", into: source.exports)
    let target = try DataWorld()
    defer { target.remove() }
    let restored = try await target.open()
    try await target.attach(restored)
    let model = RestoreWorld.model(restored, in: target)
    let runtimes = target.runtimes
    model.syncSettled = { await RestoreModel.settled(runtimes) }

    await model.refresh()
    #expect(model.isOffered, "sync is up to date with storage that brought nothing")
    await model.picked(.success(archive.url))
    #expect(try await model.confirm())

    try await MemoirSyncWorld.until("every restored store is uploaded") {
      for store in [restored.stores.main, restored.stores.activity, restored.stores.restricted] where try await !MemoirSyncWorld.isUploaded(store) { return false }
      return true
    }
  }

  @Test("should count sync as settled only once it is up to date, or off with no location attached after its launch run")
  func shouldJudgeSync() async throws {
    #expect(RestoreModel.syncAllows(.upToDate, phase: nil))
    #expect(RestoreModel.syncAllows(.off, phase: .detached))
    #expect(!RestoreModel.syncAllows(.off, phase: nil), "off before the runtime has looked")
    #expect(!RestoreModel.syncAllows(.off, phase: .deviceLocked))
    for status in [SyncStatus.syncing, .attentionNeeded(.awaitingKey), .attentionNeeded(.storageRemoved)] {
      #expect(!RestoreModel.syncAllows(status, phase: .detached))
    }
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    #expect(await !RestoreModel.settled(nil))
    #expect(await !RestoreModel.settled(world.runtimes), "the vault's sync has not launched yet")

    await world.runtimes.launch(MemoirSyncRoutes.vault(opened.stores), trustedClock: world.vault.trustedClock)

    #expect(world.runtimes.hasStarted && world.runtimes.status == .off)
    #expect(await RestoreModel.settled(world.runtimes), "no location is attached and none attaches on its own")
  }

  @Test("should neither offer nor restore while sync has not settled")
  func shouldWaitForSync() async throws {
    let source = try DataWorld()
    defer { source.remove() }
    let opened = try await source.open()
    try await RestoreWorld.fill(opened, world: source)
    let archive = try await MemoirExporter.archive(of: opened.stores, at: Date(), appVersion: "1", into: source.exports)
    let target = try DataWorld()
    defer { target.remove() }
    let restored = try await target.open()
    let model = RestoreWorld.model(restored, in: target, settled: false)

    await model.refresh()
    #expect(!model.isOffered)
    await model.picked(.success(archive.url))
    #expect(try await !model.confirm())

    guard case .failed(let error) = model.stage else { throw RestoreTestFailure("expected a refusal, got \(model.stage)") }
    #expect(error.detail == "memoir_import.sync_unsettled")
    #expect(try await MemoirRestore.isEmpty(restored.stores))
  }

  @Test("should offer only an erase for a half-restored vault, hold onboarding, and restore once the vault has been erased")
  func shouldRecoverAnUnfinishedRestore() async throws {
    let source = try DataWorld()
    defer { source.remove() }
    let opened = try await source.open()
    try await RestoreWorld.fill(opened, world: source)
    let archive = try await MemoirExporter.archive(of: opened.stores, at: Date(), appVersion: "1", into: source.exports)
    let target = try DataWorld()
    defer { target.remove() }
    let halfRestored = try await target.open()
    try await RestoreWorld.leaveUnfinished(halfRestored)
    let model = RestoreWorld.model(halfRestored, in: target)

    await model.refresh()
    #expect(model.isUnfinished && !model.isOffered)
    let deletion = target.deletion()
    await model.eraseUnfinished { () throws(VaultDeletionError) in try await deletion.delete() }

    #expect(model.eraseFailure == nil)
    let reopened = try #require(target.vault.opened)
    #expect(try await MemoirRestore.isEmpty(reopened.stores))
    #expect(try await !MemoirRestore.isUnfinished(reopened.stores))
    let again = RestoreWorld.model(reopened, in: target)
    await again.refresh()
    #expect(again.isOffered)
    await again.picked(.success(archive.url))
    #expect(try await again.confirm())
    #expect(try await !MemoirRestore.isEmpty(reopened.stores))
  }

  @Test("should take a marker beside data in the main store alone as stale, keep onboarding open and never erase")
  func shouldIgnoreAStaleMarker() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    try await RestoreWorld.leaveStaleMarker(opened)
    let model = RestoreWorld.model(opened, in: world)
    let before = try await VaultContents.read(opened.stores)
    var erased = false

    await model.refresh()
    #expect(!model.isUnfinished && !model.isOffered, "onboarding holds nothing and offers no erase")
    await model.eraseUnfinished { () throws(VaultDeletionError) in erased = true }

    #expect(!erased)
    #expect(try await VaultContents.read(opened.stores) == before)
  }

  @Test("should erase nothing when the vault is not half restored, whatever the model last read")
  func shouldEraseOnlyAHalfRestoredVault() async throws {
    let world = try DataWorld()
    defer { world.remove() }
    let opened = try await world.open()
    try await RestoreWorld.leaveUnfinished(opened)
    let model = RestoreWorld.model(opened, in: world)
    await model.refresh()
    #expect(model.isUnfinished)
    try await opened.stores.main.write { transaction in try transaction.database.execute(sql: "DROP TABLE mm_local_restore_pending") }
    var erased = false

    await model.eraseUnfinished { () throws(VaultDeletionError) in erased = true }

    #expect(!erased, "a fresh read found no half-restored vault")
    #expect(!model.isUnfinished)
  }

  @Test("should refuse a vault that holds data and write nothing")
  func shouldRefuseAVaultWithData() async throws {
    let source = try DataWorld()
    defer { source.remove() }
    let opened = try await source.open()
    try await RestoreWorld.fill(opened, world: source)
    let archive = try await MemoirExporter.archive(of: opened.stores, at: Date(), appVersion: "1", into: source.exports)
    let target = try DataWorld()
    defer { target.remove() }
    let restored = try await target.open()
    let model = RestoreWorld.model(restored, in: target)
    await model.refresh()
    await model.picked(.success(archive.url))
    _ = try await QuickLogWriter(stores: restored.stores, issuer: RestoreWorld.issuer).saveWeight(try #require(DecimalText("70.5")), on: DataWorld.day)
    let before = try await VaultContents.read(restored.stores)

    #expect(try await !model.confirm())

    guard case .failed(let error) = model.stage else { throw RestoreTestFailure("expected a refusal, got \(model.stage)") }
    #expect(error.detail == "memoir_restore.vault_not_empty")
    #expect(try await VaultContents.read(restored.stores) == before)
    #expect(!model.isOffered)
  }

  @Test("should refuse a newer version, broken JSON, a receipt path outside its place, an oversized or missing image, and write nothing")
  func shouldRefuseBrokenArchives() async throws {
    let source = try DataWorld()
    defer { source.remove() }
    let opened = try await source.open()
    let fill = try await RestoreWorld.fill(opened, world: source)
    let archive = try await MemoirExporter.archive(of: opened.stores, at: Date(), appVersion: "1", into: source.exports)
    let manifest = try JSONSerialization.jsonObject(with: try RestoreWorld.manifestData(of: archive.url)) as? [String: Any]
    let base = try #require(manifest)
    let imagePath = "receipts/\(fill.heldBlob.description).jpeg"
    let image = ["\(imagePath)": DataWorld.jpeg]
    let cases: [(String, Data, [String: Data], String)] = [
      ("newer version", try RestoreWorld.json(base) { $0["version"] = 3 }, image, "memoir_import.newer_version"),
      ("broken JSON", Data("{\"format\":".utf8), image, "memoir_import.malformed"),
      ("another format", try RestoreWorld.json(base) { $0["format"] = "com.example.other" }, image, "memoir_import.not_an_export"),
      ("traversal", try RestoreWorld.json(base) { RestoreWorld.setImage(in: &$0, file: "receipts/../../\(fill.heldBlob.description).jpeg") }, image, "memoir_import.receipt"),
      ("oversized image", try RestoreWorld.json(base) { RestoreWorld.setImage(in: &$0, byteCount: ReceiptPhoto.maximumBytes + 1) }, image, "memoir_import.receipt"),
      ("missing image", try RestoreWorld.json(base) { _ in }, [:], "memoir_import.receipt"),
      ("image of another size", try RestoreWorld.json(base) { _ in }, [imagePath: Data([1, 2, 3])], "memoir_import.receipt"),
      ("image size beyond any number", try RestoreWorld.json(base) { RestoreWorld.setImage(in: &$0, byteCount: Int.max) }, image, "memoir_import.receipt"),
      (
        "images over the total", try RestoreWorld.json(base) { RestoreWorld.listImages(in: &$0, count: 200, byteCount: ReceiptPhoto.maximumBytes) }, image,
        "memoir_import.too_large"
      ),
      ("newer registry", try RestoreWorld.json(base) { RestoreWorld.setRegistry(in: &$0, version: MemoirSchema.restrictedVersion + 1) }, image, "memoir_import.newer_records"),
      (
        "newer registry with a kind this build lacks",
        try RestoreWorld.json(base) { manifest in
          RestoreWorld.setRegistry(in: &manifest, store: "main", version: MemoirSchema.mainVersion + 1)
          RestoreWorld.addKind("mm_future", toStore: "main", in: &manifest)
        }, image, "memoir_import.newer_records"
      ),
    ]
    let target = try DataWorld()
    defer { target.remove() }
    let restored = try await target.open()
    for (name, json, images, code) in cases {
      let crafted = try RestoreWorld.archive(json, images: images, named: name, in: target)
      let model = RestoreWorld.model(restored, in: target)
      await model.picked(.success(crafted))
      guard case .failed(let error) = model.stage else {
        Issue.record("\(name) was not refused: \(model.stage)")
        continue
      }
      #expect(error.detail == code, "\(name)")
      #expect(try await MemoirRestore.isEmpty(restored.stores), "\(name) wrote nothing")
      #expect(!FileManager.default.fileExists(atPath: RestoreWorld.restores(in: target).directory.path(percentEncoded: false)), "\(name) left no image behind")
    }
  }

  @Test("should restore a version 1 export, which kept no clocks, with new revision ids under the same head text")
  func shouldRestoreVersionOne() async throws {
    let source = try DataWorld()
    defer { source.remove() }
    let opened = try await source.open()
    let fill = try await RestoreWorld.fill(opened, world: source)
    let archive = try await MemoirExporter.archive(of: opened.stores, at: Date(), appVersion: "1", into: source.exports)
    let manifest = try #require(try JSONSerialization.jsonObject(with: try RestoreWorld.manifestData(of: archive.url)) as? [String: Any])
    let versionOne = try RestoreWorld.json(manifest) { file in
      file["version"] = 1
      RestoreWorld.dropClocks(in: &file)
    }
    let target = try DataWorld()
    defer { target.remove() }
    let restored = try await target.open()
    let crafted = try RestoreWorld.archive(versionOne, images: ["receipts/\(fill.heldBlob.description).jpeg": DataWorld.jpeg], named: "v1", in: target)
    let model = RestoreWorld.model(restored, in: target)

    await model.picked(.success(crafted))
    #expect(try await model.confirm())

    let journal = JournalEntryRecord.ref(fill.journal)
    let before = try await opened.stores.main.read { transaction in try JournalEntryRecord.read(journal, in: transaction) }
    let after = try await restored.stores.main.read { transaction in try JournalEntryRecord.read(journal, in: transaction) }
    guard case .readable(let original) = before, case .readable(let copy) = after else { throw RestoreTestFailure("the journal entry is not readable") }
    #expect(copy.record.text == original.record.text)
    #expect(try await VaultContents.read(restored.stores) == VaultContents.read(opened.stores))
  }

  @Test("should accept an image path only as the export names it")
  func shouldCheckImagePaths() throws {
    let blob = try #require(BlobID(String(repeating: "ab", count: 32)))
    #expect(MemoirImporter.isImagePath("receipts/\(blob)", of: blob))
    #expect(MemoirImporter.isImagePath("receipts/\(blob).jpeg", of: blob))
    for path in ["receipts/\(blob)/../x", "receipts/\(blob).JPG", "receipts/\(blob)..jpeg", "/receipts/\(blob).jpeg", "receipts/\(blob).jp/eg", "x/receipts/\(blob)"] {
      #expect(!MemoirImporter.isImagePath(path, of: blob), "\(path)")
    }
  }
}

@Suite("ZipArchive", TestTimeLimit.quick)
struct ZipArchiveTests {
  private static let hello = Data("hello".utf8)

  @Test("should read a stored and a deflated entry and flag a symbolic link")
  func shouldReadEntries() throws {
    let zip = try ZipArchive(
      ZipBuilder(entries: [.stored("a.txt", Self.hello), .deflated("b.txt", Self.hello), .stored("link", Data("a.txt".utf8), symlink: true)]).data,
      maximumEntries: 10)
    #expect(try zip.contents(of: try #require(zip.entries["a.txt"]), maximumBytes: 100) == Self.hello)
    #expect(try zip.contents(of: try #require(zip.entries["b.txt"]), maximumBytes: 100) == Self.hello)
    #expect(zip.entries["b.txt"]?.method == 8)
    #expect(zip.entries["link"]?.isSymbolicLink == true)
  }

  @Test("should refuse an archive it cannot trust as a whole")
  func shouldRefuseArchives() throws {
    let cases: [(String, Data, ZipArchiveError)] = [
      ("not a zip", Data("not a zip".utf8), .unreadable("not a zip archive")),
      ("zip64 entry count", ZipBuilder(entries: [.stored("a", Self.hello)], count: 0xFFFF).data, .unsupported("zip64")),
      ("zip64 directory offset", ZipBuilder(entries: [.stored("a", Self.hello)], directoryOffset: 0xFFFF_FFFF).data, .unsupported("zip64")),
      ("split archive", ZipBuilder(entries: [.stored("a", Self.hello)], disk: 1).data, .unsupported("an archive split across disks")),
      ("directory outside", ZipBuilder(entries: [.stored("a", Self.hello)], directoryOffset: 9_000).data, .damaged("the central directory lies outside the archive")),
      ("encrypted", ZipBuilder(entries: [.stored("a", Self.hello, flags: 1)]).data, .unsupported("encryption")),
      ("zip64 entry size", ZipBuilder(entries: [.stored("a", Self.hello, size: 0xFFFF_FFFF)]).data, .unsupported("zip64")),
      ("non-UTF-8 name", ZipBuilder(entries: [.stored(Data([0x61, 0xFF, 0xFE]), Self.hello)]).data, .damaged("an entry name is not UTF-8")),
      ("duplicate name", ZipBuilder(entries: [.stored("a", Self.hello), .stored("a", Self.hello)]).data, .damaged("an entry name is listed twice")),
    ]
    for (name, data, expected) in cases {
      #expect(throws: expected, "\(name)") { try ZipArchive(data, maximumEntries: 10) }
    }
    #expect(throws: ZipArchiveError.tooLarge) { try ZipArchive(ZipBuilder(entries: [.stored("a", Data()), .stored("b", Data())]).data, maximumEntries: 1) }
    let url = FileManager.default.temporaryDirectory.appending(path: "zip-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: url) }
    try ZipBuilder(entries: [.stored("a.txt", Self.hello)]).data.write(to: url)
    #expect(throws: ZipArchiveError.tooLarge) { try ZipArchive(contentsOf: url, maximumBytes: 10, maximumEntries: 10) }
  }

  @Test("should refuse an entry it cannot read whole and as declared, before inflating more than it allows")
  func shouldRefuseEntries() throws {
    let longer = Data(repeating: 0x61, count: 400)
    let cases: [(String, ZipBuilder.Entry, Int)] = [
      ("checksum", .stored("a", Self.hello, crc: 1), 100),
      ("stored size differs from compressed", .stored("a", Self.hello, size: 4), 100),
      ("deflated to more than declared", .deflated("a", longer, size: 100), 1000),
      ("deflated to less than declared", .deflated("a", Self.hello, size: 50), 1000),
      ("compressed far beyond its size", .deflated("a", Self.hello, compressedSize: 1000), 1000),
      ("unknown method", .stored("a", Self.hello, method: 12), 100),
      ("local header outside", .stored("a", Self.hello, localOffset: 9_000), 100),
      ("entry past the end", .stored("a", Self.hello, compressedSize: 5, size: 5, truncatedBy: 3), 100),
      ("over the caller's limit", .stored("a", Self.hello), 4),
    ]
    for (name, entry, limit) in cases {
      let zip = try ZipArchive(ZipBuilder(entries: [entry]).data, maximumEntries: 10)
      #expect(throws: ZipArchiveError.self, "\(name)") { try zip.contents(of: try #require(zip.entries.values.first), maximumBytes: limit) }
    }
  }
}

/// A zip written by hand, so a test controls every field the reader trusts: names, methods, flags, sizes, offsets, checksums and the end record.
private struct ZipBuilder {
  struct Entry {
    var name: Data
    var payload: Data
    var method: UInt16
    var flags: UInt16 = 0
    var crc: UInt32
    var compressedSize: UInt32
    var size: UInt32
    var localOffset: UInt32?
    var symlink = false
    var truncatedBy = 0

    static func stored(
      _ name: String, _ data: Data, symlink: Bool = false, flags: UInt16 = 0, crc: UInt32? = nil, method: UInt16 = 0, compressedSize: UInt32? = nil, size: UInt32? = nil,
      localOffset: UInt32? = nil, truncatedBy: Int = 0
    ) -> Entry {
      stored(
        Data(name.utf8), data, symlink: symlink, flags: flags, crc: crc, method: method, compressedSize: compressedSize, size: size, localOffset: localOffset,
        truncatedBy: truncatedBy)
    }

    static func stored(
      _ name: Data, _ data: Data, symlink: Bool = false, flags: UInt16 = 0, crc: UInt32? = nil, method: UInt16 = 0, compressedSize: UInt32? = nil, size: UInt32? = nil,
      localOffset: UInt32? = nil, truncatedBy: Int = 0
    ) -> Entry {
      Entry(
        name: name, payload: data, method: method, flags: flags, crc: crc ?? CRC32.checksum(data), compressedSize: compressedSize ?? UInt32(data.count),
        size: size ?? UInt32(data.count), localOffset: localOffset, symlink: symlink, truncatedBy: truncatedBy)
    }

    static func deflated(_ name: String, _ data: Data, compressedSize: UInt32? = nil, size: UInt32? = nil) -> Entry {
      let payload = deflate(data)
      return Entry(
        name: Data(name.utf8), payload: payload, method: 8, crc: CRC32.checksum(data), compressedSize: compressedSize ?? UInt32(payload.count),
        size: size ?? UInt32(data.count))
    }

    private static func deflate(_ data: Data) -> Data {
      var output = Data(count: data.count + 64)
      let written = output.withUnsafeMutableBytes { destination in
        data.withUnsafeBytes { source in
          compression_encode_buffer(
            destination.bindMemory(to: UInt8.self).baseAddress!, destination.count, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
      }
      return output.prefix(written)
    }
  }

  var entries: [Entry]
  var count: UInt16?
  var directoryOffset: UInt32?
  var disk: UInt16 = 0

  var data: Data {
    var archive = Data()
    var directory = Data()
    for entry in entries {
      let offset = UInt32(archive.count)
      archive.append(le32(0x0403_4b50) + le16(20) + le16(entry.flags) + le16(entry.method) + le16(0) + le16(0) + le32(entry.crc))
      archive.append(le32(entry.compressedSize) + le32(entry.size) + le16(UInt16(entry.name.count)) + le16(0) + entry.name)
      archive.append(entry.payload.dropLast(entry.truncatedBy))
      let mode: UInt32 = entry.symlink ? 0o120777 : 0o100644
      directory.append(le32(0x0201_4b50) + le16(3 << 8 | 20) + le16(20) + le16(entry.flags) + le16(entry.method) + le16(0) + le16(0) + le32(entry.crc))
      directory.append(le32(entry.compressedSize) + le32(entry.size) + le16(UInt16(entry.name.count)) + le16(0) + le16(0) + le16(0) + le16(0))
      directory.append(le32(mode << 16) + le32(entry.localOffset ?? offset) + entry.name)
    }
    let start = UInt32(archive.count)
    let listed = count ?? UInt16(entries.count)
    archive.append(directory)
    archive.append(le32(0x0605_4b50) + le16(disk) + le16(0) + le16(listed) + le16(listed) + le32(UInt32(directory.count)))
    archive.append(le32(directoryOffset ?? start) + le16(0))
    return archive
  }

  private func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
  private func le32(_ value: UInt32) -> Data { le16(UInt16(value & 0xFFFF)) + le16(UInt16(value >> 16)) }
}

@MainActor
private enum RestoreWorld {
  struct Filled {
    let heldBlob: BlobID
    let journal: UUID
  }

  static var issuer: CommandIssuerSource {
    let issuer = CommandIssuer(clock: IssueClock(timeZone: .gmt), wallClock: { Date() })
    return CommandIssuerSource { _ in issuer }
  }

  static func model(_ opened: MemoirOpenedVault, in world: DataWorld, settled: Bool = true) -> RestoreModel {
    let model = RestoreModel(context: MemoirScreenContext(opened), restores: restores(in: world))
    model.syncSettled = { settled }
    return model
  }

  /// What a restore stopped between its commits leaves: the health store's data and the main store's marker, with no data in main.
  static func leaveUnfinished(_ opened: MemoirOpenedVault) async throws {
    let weight = EntityRef(kind: MemoirKind.weight.entityKind, key: try #require(EntityKey("weight-2026-11-20")))
    try await opened.stores.restricted.write { transaction in _ = try transaction.set(weight, ["kilograms": "70.5"]) }
    try await mark(opened)
  }

  /// A restore stopped before any store committed, after which the Mac's Settings window wrote to the main store.
  static func leaveStaleMarker(_ opened: MemoirOpenedVault) async throws {
    try await mark(opened)
    let category = try #require(CategoryKey("food"))
    let expense = ExpenseRecord(id: UUID(), amountMinor: 500, currency: try #require(CurrencyCode("EUR")), occurredOn: DataWorld.day, category: category, loggedAtMillis: 1)
    try await opened.stores.main.write { transaction in _ = try expense.create(in: &transaction) }
  }

  private static func mark(_ opened: MemoirOpenedVault) async throws {
    try await opened.stores.main.write { transaction in
      try transaction.database.execute(
        sql: """
          CREATE TABLE mm_local_restore_pending (id INTEGER PRIMARY KEY CHECK (id = 1), started_at_millis INTEGER NOT NULL) STRICT;
          INSERT INTO mm_local_restore_pending (id, started_at_millis) VALUES (1, 0);
          """)
    }
  }

  static func listImages(in manifest: inout [String: Any], count: Int, byteCount: Int) {
    manifest["receiptImages"] = (0..<count).map { index in
      let blob = String(format: "%064x", index)
      return ["receipt": UUID().uuidString.lowercased(), "blob": blob, "contentType": "image/jpeg", "byteCount": byteCount, "file": "receipts/\(blob).jpeg"] as [String: Any]
    }
  }

  static func restores(in world: DataWorld) -> MemoirRestores {
    MemoirRestores(directory: world.directory.appending(path: "Restores", directoryHint: .isDirectory))
  }

  /// The demo's week, then the data world's records of every class, two edits of its journal entry and a weekly review.
  @discardableResult
  static func fill(_ opened: MemoirOpenedVault, world: DataWorld) async throws -> Filled {
    try await MemoirDemo.seed(opened.stores, now: Date(), zone: .gmt, currency: try #require(CurrencyCode("EUR")))
    let fill = try await world.fill(opened)
    for text in ["Walked home the long way, twice.", "Walked home the long way, three times."] {
      try await opened.stores.main.write { transaction in _ = try JournalEntryRecord.edit(JournalEntryRecord.ref(fill.journal), in: &transaction) { $0.text = text } }
    }
    return Filled(heldBlob: fill.heldBlob, journal: fill.journal)
  }

  static func manifestData(of archive: URL) throws -> Data {
    let zip = try ZipArchive(contentsOf: archive, maximumBytes: MemoirImporter.maximumArchiveBytes, maximumEntries: 100)
    let entry = try #require(zip.entries.values.first { $0.name.hasSuffix(MemoirExportFile.fileName) })
    return try zip.contents(of: entry, maximumBytes: MemoirImporter.maximumManifestBytes)
  }

  static func manifest(of archive: URL) throws -> MemoirExportFile {
    try JSONDecoder().decode(MemoirExportFile.self, from: try manifestData(of: archive))
  }

  /// The file without what a restore cannot keep: when it was made, and the clocks an import stamps anew, whose order must survive.
  static func normalised(_ file: MemoirExportFile) -> MemoirExportFile {
    let stores = file.stores.map { store in
      MemoirExportFile.Store(
        name: store.name, registryVersion: store.registryVersion,
        kinds: store.kinds.map { kind in
          let ordered = kind.entries.sorted { first, second in
            guard let one = first.clock.flatMap(HLCTimestamp.init), let other = second.clock.flatMap(HLCTimestamp.init), one != other else { return first.key < second.key }
            return one < other
          }
          return MemoirExportFile.Kind(
            kind: kind.kind, syncClass: kind.syncClass, shape: kind.shape,
            entries: ordered.map { entry in
              var entry = entry
              entry.clock = nil
              return entry
            })
        })
    }
    return MemoirExportFile(
      format: file.format, version: file.version, generatedAt: "", appVersion: file.appVersion, stores: stores, receiptImages: file.receiptImages,
      local: file.local, derived: file.derived)
  }

  static func json(_ base: [String: Any], _ change: (inout [String: Any]) -> Void) throws -> Data {
    var copy = base
    change(&copy)
    return try JSONSerialization.data(withJSONObject: copy)
  }

  static func dropClocks(in manifest: inout [String: Any]) {
    guard var stores = manifest["stores"] as? [[String: Any]] else { return }
    for store in stores.indices {
      guard var kinds = stores[store]["kinds"] as? [[String: Any]] else { continue }
      for kind in kinds.indices {
        guard var entries = kinds[kind]["entries"] as? [[String: Any]] else { continue }
        for entry in entries.indices {
          entries[entry]["clock"] = nil
          guard var revisions = entries[entry]["revisions"] as? [[String: Any]] else { continue }
          for revision in revisions.indices { revisions[revision]["created"] = nil }
          entries[entry]["revisions"] = revisions
        }
        kinds[kind]["entries"] = entries
      }
      stores[store]["kinds"] = kinds
    }
    manifest["stores"] = stores
  }

  static func setImage(in manifest: inout [String: Any], file: String? = nil, byteCount: Int? = nil) {
    guard var images = manifest["receiptImages"] as? [[String: Any]] else { return }
    for index in images.indices where images[index]["file"] is String {
      if let file { images[index]["file"] = file }
      if let byteCount { images[index]["byteCount"] = byteCount }
    }
    manifest["receiptImages"] = images
  }

  static func setRegistry(in manifest: inout [String: Any], store: String = "health", version: Int) {
    guard var stores = manifest["stores"] as? [[String: Any]] else { return }
    for index in stores.indices where stores[index]["name"] as? String == store { stores[index]["registryVersion"] = version }
    manifest["stores"] = stores
  }

  static func addKind(_ kind: String, toStore store: String, in manifest: inout [String: Any]) {
    guard var stores = manifest["stores"] as? [[String: Any]] else { return }
    for index in stores.indices where stores[index]["name"] as? String == store {
      let kinds = stores[index]["kinds"] as? [[String: Any]] ?? []
      stores[index]["kinds"] = kinds + [["kind": kind, "syncClass": "general", "shape": "record", "entries": [[String: Any]]()]]
    }
    manifest["stores"] = stores
  }

  /// A folder zipped as `MemoirExporter` zips one, holding `json` as the export and `images` at their paths.
  static func archive(_ json: Data, images: [String: Data], named name: String, in world: DataWorld) throws -> URL {
    let work = world.directory.appending(path: "Crafted-\(UUID().uuidString)", directoryHint: .isDirectory)
    let folder = work.appending(path: "memoir-export", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder.appending(path: MemoirExportFile.receiptsFolder), withIntermediateDirectories: true)
    try json.write(to: folder.appending(path: MemoirExportFile.fileName))
    for (path, data) in images { try data.write(to: folder.appending(path: path)) }
    let archive = work.appending(path: "\(name).zip")
    var coordination: NSError?
    var moved: (any Error)?
    NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zipped in
      do {
        try FileManager.default.moveItem(at: zipped, to: archive)
      } catch {
        moved = error
      }
    }
    if let failure = coordination ?? moved { throw failure }
    return archive
  }
}

private struct RestoreTestFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
