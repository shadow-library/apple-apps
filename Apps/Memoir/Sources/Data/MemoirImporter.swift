import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore
import ShadowSync

nonisolated enum MemoirImportError: ShadowError, Equatable {
  /// Not a zip archive, or one this reader cannot open.
  case unreadable(String)
  /// A zip archive without Memoir's export in it.
  case notAnExport
  case newerVersion(Int)
  /// A store's records were written under a newer registry than this build reads.
  case newerRecords(String)
  case malformed(String)
  case tooLarge
  case receipt(String)
  case file(String)
  /// Sync is bringing data, waiting for a key or needs attention, so the storage may hold this vault's data already.
  case syncUnsettled

  var code: String {
    switch self {
    case .unreadable: "memoir_import.unreadable"
    case .notAnExport: "memoir_import.not_an_export"
    case .newerVersion: "memoir_import.newer_version"
    case .newerRecords: "memoir_import.newer_records"
    case .malformed: "memoir_import.malformed"
    case .tooLarge: "memoir_import.too_large"
    case .receipt: "memoir_import.receipt"
    case .file: "memoir_import.file"
    case .syncUnsettled: "memoir_import.sync_unsettled"
    }
  }

  var errorDescription: String? {
    switch self {
    case .unreadable(let reason), .newerRecords(let reason), .malformed(let reason), .receipt(let reason), .file(let reason): reason
    case .notAnExport: "The archive holds no Memoir export."
    case .newerVersion(let version): "The export is version \(version); this build reads up to version \(MemoirExportFile.currentVersion)."
    case .tooLarge: "The archive is larger than a restore takes."
    case .syncUnsettled: "Sync has not settled."
    }
  }
}

/// Where a restore keeps the receipt images it read from the archive until they are in the vault: one folder at a time in the app's temporary directory,
/// removed when the restore ends or is cancelled and at the next launch.
nonisolated struct MemoirRestores: Sendable {
  let directory: URL

  static var live: MemoirRestores {
    MemoirRestores(directory: FileManager.default.temporaryDirectory.appending(path: "\(AppIdentity.memoir.id).restores", directoryHint: .isDirectory))
  }

  static func clearLeftovers() {
    live.clear()
  }

  func clear() {
    try? FileManager.default.removeItem(at: directory)
  }
}

/// What the confirmation shows before anything is written, with the contents the restore writes.
nonisolated struct MemoirRestorePreview: Sendable {
  let contents: MemoirRestoreContents
  let generatedAt: Date?
  let appVersion: String
  let entries: [MemoirStoreKind: Int]
  let vaultContents: VaultContents
  let receiptImages: Int
  let receiptsWithoutImage: Int
  let weeklyReviews: Int
}

extension MemoirRestorePreview: Equatable {
  static func == (lhs: MemoirRestorePreview, rhs: MemoirRestorePreview) -> Bool {
    lhs.generatedAt == rhs.generatedAt && lhs.appVersion == rhs.appVersion && lhs.entries == rhs.entries && lhs.vaultContents == rhs.vaultContents
      && lhs.receiptImages == rhs.receiptImages && lhs.receiptsWithoutImage == rhs.receiptsWithoutImage && lhs.weeklyReviews == rhs.weeklyReviews
  }
}

/// Reads an archive `MemoirExporter` made (or the owner zipped again) as untrusted input: sizes are bounded before anything is inflated, the export is
/// found only at the archive's root or in one folder, receipt images only at the exact path the export names for their blob, symbolic links are refused,
/// and every check runs before the restore writes anything. Receipt images are copied into `MemoirRestores` under their blob id, never under a name
/// from the archive.
nonisolated enum MemoirImporter {
  static let maximumArchiveBytes = 2 * 1024 * 1024 * 1024
  static let maximumManifestBytes = 256 * 1024 * 1024
  static let maximumImageBytes = 1024 * 1024 * 1024
  static let maximumEntries = 60_000
  private static let archiveName = "archive.zip"

  /// The picked file is copied under file coordination into the restores folder first, so a file provider's copy is whole and nothing maps a file another
  /// process may change; the copy goes once the images are out.
  @concurrent
  static func read(_ archive: URL, into restores: MemoirRestores) async throws(MemoirImportError) -> MemoirRestorePreview {
    restores.clear()
    let work = restores.directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    } catch {
      throw .file(error.localizedDescription)
    }
    let local = work.appending(path: archiveName, directoryHint: .notDirectory)
    defer { try? FileManager.default.removeItem(at: local) }
    do throws(MemoirImportError) {
      try copy(archive, to: local)
      return try read(local, extractingInto: work)
    } catch {
      restores.clear()
      throw error
    }
  }

  private static func copy(_ archive: URL, to local: URL) throws(MemoirImportError) {
    var coordination: NSError?
    var failure: MemoirImportError?
    NSFileCoordinator().coordinate(readingItemAt: archive, options: .withoutChanges, error: &coordination) { readable in
      guard let size = try? readable.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
        failure = .unreadable("the file cannot be read")
        return
      }
      guard size <= maximumArchiveBytes else {
        failure = .tooLarge
        return
      }
      do {
        try FileManager.default.copyItem(at: readable, to: local)
      } catch {
        failure = .file(error.localizedDescription)
      }
    }
    if let coordination { throw .unreadable(coordination.localizedDescription) }
    if let failure { throw failure }
  }

  private static func read(_ archive: URL, extractingInto work: URL) throws(MemoirImportError) -> MemoirRestorePreview {
    let zip: ZipArchive
    do {
      zip = try ZipArchive(contentsOf: archive, maximumBytes: maximumArchiveBytes, maximumEntries: maximumEntries)
    } catch {
      throw error.importError
    }
    let (manifest, folder) = try locateManifest(in: zip)
    let file: MemoirExportFile
    do {
      file = try JSONDecoder().decode(MemoirExportFile.self, from: try zip.contents(of: manifest, maximumBytes: maximumManifestBytes))
    } catch let error as ZipArchiveError {
      throw error.importError
    } catch {
      throw .malformed("memoir-export.json does not decode: \(String(describing: error).prefix(200))")
    }
    var listed = 0
    for image in file.receiptImages where image.file != nil {
      guard (1...ReceiptPhoto.maximumBytes).contains(image.byteCount) else { throw .receipt("receipt image \(image.blob) is larger than a receipt image can be") }
      let (sum, overflow) = listed.addingReportingOverflow(image.byteCount)
      guard !overflow, sum <= maximumImageBytes else { throw .tooLarge }
      listed = sum
    }
    let preview = try self.preview(of: file) { image throws(MemoirImportError) in try extract(image, from: zip, folder: folder, into: work) }
    try check(preview.contents)
    return preview
  }

  private static func check(_ contents: MemoirRestoreContents) throws(MemoirImportError) {
    do {
      try MemoirRestore.check(contents)
    } catch {
      switch error {
      case .registryTooNew, .rulesetTooNew: throw .newerRecords(error.errorDescription ?? error.code)
      case .receipt(let reason): throw .receipt(reason)
      default: throw .malformed(error.errorDescription ?? error.code)
      }
    }
  }

  /// The archive's own name for the export is never trusted: the restore takes `memoir-export.json` from the root or from the one folder that holds it.
  private static func locateManifest(in zip: ZipArchive) throws(MemoirImportError) -> (ZipArchive.Entry, folder: String) {
    let found = zip.entries.values.filter { entry in
      let parts = entry.name.split(separator: "/", omittingEmptySubsequences: false)
      return parts.last.map(String.init) == MemoirExportFile.fileName && parts.count <= 2 && !entry.name.hasPrefix("__MACOSX/")
    }
    guard let manifest = found.first else { throw .notAnExport }
    guard found.count == 1 else { throw .malformed("the archive holds more than one export") }
    guard !manifest.isSymbolicLink else { throw .malformed("the export is a symbolic link") }
    return (manifest, String(manifest.name.dropLast(MemoirExportFile.fileName.count)))
  }

  private static func extract(
    _ image: MemoirExportFile.ReceiptImage, from zip: ZipArchive, folder: String, into work: URL
  ) throws(MemoirImportError) -> MemoirRestoreContents.ReceiptImage? {
    guard let path = image.file else { return nil }
    guard let blob = BlobID(image.blob) else { throw .receipt("a receipt image names no blob id") }
    guard isImagePath(path, of: blob) else { throw .receipt("receipt image \(blob) is not where an export keeps it") }
    guard image.byteCount > 0, image.byteCount <= ReceiptPhoto.maximumBytes else { throw .receipt("receipt image \(blob) is larger than a receipt image can be") }
    guard let entry = zip.entries[folder + path] else { throw .receipt("receipt image \(blob) is missing from the archive") }
    guard !entry.isSymbolicLink, !entry.isDirectory else { throw .receipt("receipt image \(blob) is not a file") }
    guard entry.size == image.byteCount else { throw .receipt("receipt image \(blob) is not the size the export records") }
    let url = work.appending(path: blob.description, directoryHint: .notDirectory)
    do {
      try zip.contents(of: entry, maximumBytes: ReceiptPhoto.maximumBytes).write(to: url, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
    } catch let error as ZipArchiveError {
      throw .receipt("receipt image \(blob) is damaged: \(error.importError.errorDescription ?? "")")
    } catch {
      throw .file(error.localizedDescription)
    }
    return MemoirRestoreContents.ReceiptImage(blob: blob, file: url)
  }

  /// `receipts/<blob id>` with at most one short extension of lower-case letters and digits, as `MemoirExporter` names it; nothing else can traverse.
  static func isImagePath(_ path: String, of blob: BlobID) -> Bool {
    let prefix = "\(MemoirExportFile.receiptsFolder)/\(blob.description)"
    guard path.utf8.starts(with: prefix.utf8) else { return false }
    let rest = path.utf8.dropFirst(prefix.utf8.count)
    guard let dot = rest.first else { return true }
    let ext = rest.dropFirst()
    return dot == UInt8(ascii: ".") && (1...10).contains(ext.count)
      && ext.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
  }

  /// The file's contents as the restore writes them, checked for shape; `image` turns each listed receipt image into a file the restore can stage.
  static func preview(
    of file: MemoirExportFile, image: (MemoirExportFile.ReceiptImage) throws(MemoirImportError) -> MemoirRestoreContents.ReceiptImage?
  ) throws(MemoirImportError) -> MemoirRestorePreview {
    guard file.format == MemoirExportFile.format else { throw .notAnExport }
    guard file.version <= MemoirExportFile.currentVersion else { throw .newerVersion(file.version) }
    guard file.version >= 1 else { throw .malformed("version \(file.version) was never written") }
    let keepsClocks = file.version >= 2
    var stores = [MemoirStoreKind: MemoirRestoreContents.Store]()
    for section in file.stores {
      guard let kind = MemoirStoreKind.allCases.first(where: { MemoirExporter.storeName($0) == section.name }) else { throw .malformed("unknown store \(section.name)") }
      guard stores[kind] == nil else { throw .malformed("store \(section.name) is listed twice") }
      var entities = [ImportedEntity]()
      for kindSection in section.kinds { entities += try self.entities(of: kindSection, in: kind, keepsClocks: keepsClocks) }
      stores[kind] = MemoirRestoreContents.Store(registryVersion: section.registryVersion, entities: entities)
    }
    var images = [MemoirRestoreContents.ReceiptImage]()
    for listed in file.receiptImages {
      if let extracted = try image(listed) { images.append(extracted) }
    }
    let contents = MemoirRestoreContents(stores: stores, receiptImages: images, weeklyReviews: try weeklyReviews(file.local))
    return MemoirRestorePreview(
      contents: contents, generatedAt: try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(file.generatedAt), appVersion: file.appVersion,
      entries: stores.mapValues(\.entities.count), vaultContents: vaultContents(of: stores), receiptImages: images.count,
      receiptsWithoutImage: file.receiptImages.count - images.count, weeklyReviews: file.local.weeklyReviews.count)
  }

  private static func entities(of section: MemoirExportFile.Kind, in store: MemoirStoreKind, keepsClocks: Bool) throws(MemoirImportError) -> [ImportedEntity] {
    guard let kind = EntityKind(section.kind), let schema = store.registry[kind] else {
      throw .malformed("kind \(section.kind) is not one the \(MemoirExporter.storeName(store)) store holds")
    }
    guard schema.syncClass.rawValue == section.syncClass else { throw .malformed("kind \(section.kind) is not of sync class \(section.syncClass)") }
    var ordered = [(clock: HLCTimestamp?, entity: ImportedEntity)]()
    for entry in section.entries {
      guard let key = EntityKey(entry.key) else { throw .malformed("an entry of \(section.kind) has no valid key") }
      let ref = EntityRef(kind: kind, key: key)
      switch (section.shape, schema.shape) {
      case ("record", .record):
        guard let fields = entry.fields, entry.item == nil, entry.head == nil, entry.revisions == nil else { throw malformed(ref) }
        ordered.append((nil, .record(ref, fields: fields)))
      case ("appended", .appended):
        guard let item = entry.item, entry.fields == nil, entry.head == nil, entry.revisions == nil else { throw malformed(ref) }
        let clock = try entry.clock.map { text throws(MemoirImportError) in
          guard let clock = HLCTimestamp(text) else { throw malformed(ref) }
          return clock
        }
        guard (clock != nil) == keepsClocks else { throw malformed(ref) }
        ordered.append((clock, .appended(ref, item: item)))
      case ("revisioned", .revisioned):
        guard entry.item == nil, entry.clock == nil else { throw malformed(ref) }
        let revisions = try (entry.revisions ?? []).map { revision throws(MemoirImportError) in
          let created = try revision.created.map { text throws(MemoirImportError) in
            guard let created = HLCTimestamp(text) else { throw malformed(ref) }
            return created
          }
          guard (created != nil) == keepsClocks else { throw malformed(ref) }
          return ImportedRevision(id: revision.id, parent: revision.parent, body: revision.body, generation: revision.generation, created: created)
        }
        ordered.append((nil, .revisioned(ref, fields: entry.fields ?? [:], head: entry.head, revisions: revisions)))
      default:
        throw .malformed("kind \(section.kind) is not shaped \(section.shape)")
      }
    }
    return ordered.sorted { first, second in
      guard let one = first.clock, let other = second.clock, one != other else { return first.entity.ref < second.entity.ref }
      return one < other
    }
    .map(\.entity)
  }

  private static func malformed(_ ref: EntityRef) -> MemoirImportError {
    .malformed("\(ref.kind)/\(ref.key) is not shaped as its kind is exported")
  }

  private static func weeklyReviews(_ local: MemoirExportFile.Local) throws(MemoirImportError) -> [LocalDate: ReviewAnswers] {
    var weeks = [LocalDate: ReviewAnswers]()
    for review in local.weeklyReviews {
      guard let week = LocalDate(isoString: review.week), weeks[week] == nil else { throw .malformed("a weekly review names no week, or a week twice") }
      var answers = [ReviewPrompt: String]()
      for (prompt, answer) in review.answers {
        guard let prompt = ReviewPrompt(rawValue: prompt) else { throw .malformed("a weekly review answers an unknown prompt") }
        answers[prompt] = answer
      }
      weeks[week] = ReviewAnswers(answers: answers, completedAtMillis: review.completedAtMillis)
    }
    return weeks
  }

  /// Counted as the export and deletion screens count a vault: live records, every appended item.
  private static func vaultContents(of stores: [MemoirStoreKind: MemoirRestoreContents.Store]) -> VaultContents {
    var counts = [MemoirKind: Int]()
    for entity in stores.values.flatMap(\.entities) {
      guard let kind = MemoirKind(entity.ref.kind) else { continue }
      let removed: Bool
      switch entity {
      case .record(_, let fields), .revisioned(_, let fields, _, _): removed = fields["removed"] == .bool(true)
      case .appended: removed = false
      }
      if !removed { counts[kind, default: 0] += 1 }
    }
    return VaultContents(counts: counts)
  }
}

extension ZipArchiveError {
  nonisolated fileprivate var importError: MemoirImportError {
    switch self {
    case .tooLarge: .tooLarge
    case .unreadable(let reason), .unsupported(let reason), .damaged(let reason): .unreadable(reason)
    }
  }
}
