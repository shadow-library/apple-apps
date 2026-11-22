import Foundation
import MemoirCore
import OSLog
import ShadowAppShell
import ShadowCore
import ShadowStore
import ShadowSync
import UniformTypeIdentifiers

nonisolated enum MemoirExportError: ShadowError, Equatable {
  case store(String)
  case file(String)

  var code: String {
    switch self {
    case .store: "memoir_export.store"
    case .file: "memoir_export.file"
    }
  }

  var errorDescription: String? {
    switch self {
    case .store(let reason), .file(let reason): reason
    }
  }
}

/// Where archives wait to be saved or shared: one at a time, in the app's temporary directory, cleared before the next and when the vault is deleted.
nonisolated struct MemoirExports: Sendable {
  let directory: URL

  static var live: MemoirExports {
    MemoirExports(directory: FileManager.default.temporaryDirectory.appending(path: "\(AppIdentity.memoir.id).exports", directoryHint: .isDirectory))
  }

  /// At launch: an archive an earlier run left (quit or stopped before it was cleared) holds health data in plain text.
  static func clearLeftovers() {
    do {
      try live.clear()
    } catch {
      Logger(subsystem: AppIdentity.memoir.id, category: "export").error("A waiting archive was not removed code=\(error.code, privacy: .public)")
    }
  }

  func clear(fileManager: FileManager = .default) throws(MemoirExportError) {
    guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
    do {
      try fileManager.removeItem(at: directory)
    } catch {
      throw .file(error.localizedDescription)
    }
  }
}

/// A zip archive on this device: `memoir-export.json` and the receipt images this device holds, zipped by the system's file coordinator, so no
/// archiver beyond Foundation is needed.
nonisolated struct MemoirExportArchive: Equatable, Sendable {
  let url: URL
  let missingImages: Int

  var fileName: String { url.lastPathComponent }
}

nonisolated enum MemoirExporter {
  static let derivedNote = "Worked out from the command log by this version of Memoir when the export was made. It is not a record and is never read back."

  @concurrent
  static func archive(
    of stores: MemoirStores, at now: Date, appVersion: String, into exports: MemoirExports, fileManager: FileManager = .default
  ) async throws(MemoirExportError) -> MemoirExportArchive {
    try exports.clear(fileManager: fileManager)
    let name = "memoir-export-\(now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()))"
    let work = exports.directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let folder = work.appending(path: name, directoryHint: .isDirectory)
    defer { try? fileManager.removeItem(at: work) }
    let receipts = try await receipts(in: stores.main)
    var images = [MemoirExportFile.ReceiptImage]()
    do {
      try fileManager.createDirectory(at: folder.appending(path: MemoirExportFile.receiptsFolder), withIntermediateDirectories: true)
      for receipt in receipts {
        var file: String?
        if let held = receipt.held {
          let path = "\(MemoirExportFile.receiptsFolder)/\(receipt.image.blob)\(fileExtension(of: receipt.image.contentType))"
          try fileManager.copyItem(at: held, to: folder.appending(path: path))
          file = path
        }
        images.append(
          MemoirExportFile.ReceiptImage(
            receipt: receipt.image.receipt, blob: receipt.image.blob, contentType: receipt.image.contentType, byteCount: receipt.image.byteCount, file: file))
      }
    } catch {
      throw .file(error.localizedDescription)
    }
    let file = try await self.file(of: stores, at: now, appVersion: appVersion, receiptImages: images)
    do {
      try encode(file).write(to: folder.appending(path: MemoirExportFile.fileName), options: .atomic)
    } catch {
      throw .file(error.localizedDescription)
    }
    let archive = exports.directory.appending(path: "\(name).zip", directoryHint: .notDirectory)
    try zip(folder, to: archive, fileManager: fileManager)
    return MemoirExportArchive(url: archive, missingImages: images.count { $0.file == nil })
  }

  static func file(
    of stores: MemoirStores, at now: Date, appVersion: String, receiptImages: [MemoirExportFile.ReceiptImage]
  ) async throws(MemoirExportError) -> MemoirExportFile {
    var sections = [MemoirExportFile.Store]()
    for kind in MemoirStoreKind.allCases { sections.append(try await section(kind, of: stores.store(kind))) }
    return MemoirExportFile(
      format: MemoirExportFile.format, version: MemoirExportFile.currentVersion, generatedAt: now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
      appVersion: appVersion, stores: sections, receiptImages: receiptImages, local: try await local(in: stores.main), derived: await derived(from: stores.main))
  }

  private static func local(in main: VaultStore) async throws(MemoirExportError) -> MemoirExportFile.Local {
    do {
      let weeks = try await main.read { transaction in try WeeklyReviewAnswers.weeks(in: transaction) }
      return MemoirExportFile.Local(
        weeklyReviews: weeks.sorted { $0.key < $1.key }.map { week, review in
          MemoirExportFile.WeeklyReview(
            week: week.isoString, answers: Dictionary(uniqueKeysWithValues: review.answers.map { ($0.key.rawValue, $0.value) }),
            completedAtMillis: review.completedAtMillis)
        })
    } catch {
      throw .store(error.code)
    }
  }

  static func encode(_ file: MemoirExportFile) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(file)
  }

  static func storeName(_ kind: MemoirStoreKind) -> String {
    switch kind {
    case .main: "main"
    case .activity: "activity"
    case .restricted: "health"
    }
  }

  private static func section(_ kind: MemoirStoreKind, of store: VaultStore) async throws(MemoirExportError) -> MemoirExportFile.Store {
    let schemas = store.registry.schemas.filter { !$0.kind.rawValue.hasPrefix(MemoirExportFile.excludedKindPrefix) }
    do {
      let kinds = try await store.read { transaction in
        try schemas.map { schema in
          let entries = try transaction.states(ofKind: schema.kind, scope: .vault).sorted { $0.ref < $1.ref }.compactMap { entry(of: $0.ref, $0.state) }
          return MemoirExportFile.Kind(kind: schema.kind.rawValue, syncClass: schema.syncClass.rawValue, shape: shape(schema.shape), entries: entries)
        }
      }
      return MemoirExportFile.Store(name: storeName(kind), registryVersion: store.registry.version, kinds: kinds)
    } catch {
      throw .store(error.code)
    }
  }

  private static func entry(of ref: EntityRef, _ state: EntityState) -> MemoirExportFile.Entry? {
    var entry = MemoirExportFile.Entry(key: ref.key.rawValue)
    switch state {
    case .purged:
      return nil
    case .record(let record):
      entry.fields = fields(record.fields)
    case .appended(let appended):
      entry.item = appended.item
    case .revisioned(let document):
      entry.fields = fields(document.fields)
      entry.head = document.headRevision
      entry.revisions = document.revisions.map { id, item in
        MemoirExportFile.Revision(id: id.value, parent: item.parent, generation: item.generation, body: item.body)
      }
      .sorted { ($0.generation, $0.id) < ($1.generation, $1.id) }
    }
    return entry
  }

  private static func fields(_ fields: [ExactString: FieldState]) -> [String: JSONValue] {
    Dictionary(fields.map { ($0.key.value, $0.value.value) }) { first, _ in first }
  }

  private static func shape(_ shape: EntityShape) -> String {
    switch shape {
    case .record: "record"
    case .appended: "appended"
    case .revisioned: "revisioned"
    }
  }

  private struct HeldReceipt: Sendable {
    let image: MemoirExportFile.ReceiptImage
    let held: URL?
  }

  /// Removed receipts are exported too, as their records are; an image whose blob this device lacks, or a store with no files, is listed without one.
  private static func receipts(in main: VaultStore) async throws(MemoirExportError) -> [HeldReceipt] {
    let listing: MemoirListing<MemoirEntry<ReceiptRecord>>
    do {
      listing = try await main.read { transaction in try ReceiptRecord.listing(in: transaction) }
    } catch {
      throw .store(error.code)
    }
    let blobs = try? VaultBlobs(store: main)
    var receipts = [HeldReceipt]()
    for receipt in listing.entries.map(\.record) {
      let held: URL?
      if let blobs, let id = BlobID(receipt.blob.name) { held = try? await blobs.localURL(of: id) } else { held = nil }
      let image = MemoirExportFile.ReceiptImage(
        receipt: receipt.ref.key.rawValue, blob: receipt.blob.name, contentType: receipt.contentType, byteCount: receipt.byteCount, file: nil)
      receipts.append(HeldReceipt(image: image, held: held))
    }
    return receipts
  }

  private static func derived(from main: VaultStore) async -> MemoirExportFile.Derived? {
    guard let deck = try? await main.load(HeroDeck.self, HeroDeckQuery()) else { return nil }
    return MemoirExportFile.Derived(note: derivedNote, level: deck.level.level, totalXP: deck.level.totalXP, coins: deck.coins)
  }

  private static func fileExtension(of contentType: String) -> String {
    UTType(mimeType: contentType)?.preferredFilenameExtension.map { ".\($0)" } ?? ""
  }

  /// A directory read "for uploading" is handed over as a zip of its contents, which is unlinked once the accessor returns, so it is moved out inside.
  private static func zip(_ folder: URL, to archive: URL, fileManager: FileManager) throws(MemoirExportError) {
    var coordination: NSError?
    var moved: (any Error)?
    NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zipped in
      do {
        try fileManager.moveItem(at: zipped, to: archive)
      } catch {
        moved = error
      }
    }
    if let failure = coordination ?? moved { throw .file(failure.localizedDescription) }
  }
}
