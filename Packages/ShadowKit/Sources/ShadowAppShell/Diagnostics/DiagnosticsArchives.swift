import Foundation
import OSLog
import ShadowCore

/// A diagnostics zip on this device, waiting to be saved or shared.
nonisolated struct DiagnosticsArchive: Equatable, Sendable {
  let url: URL
  let summary: String

  var fileName: String { url.lastPathComponent }
}

/// Where diagnostics archives wait: one at a time, in the app's temporary directory, removed before the next, when the screen goes away and at launch.
public nonisolated struct DiagnosticsArchives: Sendable {
  static let summaryFile = "summary.json"
  static let logFile = "log.txt"

  let directory: URL

  static func live(identity: AppIdentity) -> DiagnosticsArchives {
    DiagnosticsArchives(directory: FileManager.default.temporaryDirectory.appending(path: "\(identity.id).diagnostics", directoryHint: .isDirectory))
  }

  /// At launch: an archive an earlier run left (quit or stopped before the screen went away).
  public static func clearLeftovers(identity: AppIdentity) {
    do {
      try live(identity: identity).clear()
    } catch {
      Logger(category: "diagnostics").error("A waiting diagnostics archive was not removed code=\(error.code, privacy: .public)")
    }
  }

  func clear(fileManager: FileManager = .default) throws(DiagnosticsError) {
    guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
    do {
      try fileManager.removeItem(at: directory)
    } catch {
      throw .file(error.localizedDescription)
    }
  }

  /// Clears what waits, then writes the scrubbed summary and log into a folder named after the app and the day and zips it with the system's file
  /// coordinator, so no archiver beyond Foundation is needed.
  func archive(
    app: AppIdentity, summary: DiagnosticsSummary, log: DiagnosticsLog.Read, at now: Date, fileManager: FileManager = .default
  ) throws(DiagnosticsError) -> DiagnosticsArchive {
    try clear(fileManager: fileManager)
    let name = "\(Self.slug(of: app))-diagnostics-\(now.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()))"
    let work = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let folder = work.appending(path: name, directoryHint: .isDirectory)
    defer { try? fileManager.removeItem(at: work) }
    let summaryText = DiagnosticsScrub.apply(try summary.encoded())
    let logText = DiagnosticsScrub.apply(log.lines.joined(separator: "\n") + (log.lines.isEmpty ? "" : "\n"))
    do {
      try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data(summaryText.utf8).write(to: folder.appending(path: Self.summaryFile), options: .atomic)
      try Data(logText.utf8).write(to: folder.appending(path: Self.logFile), options: .atomic)
    } catch {
      throw .file(error.localizedDescription)
    }
    let archive = directory.appending(path: "\(name).zip", directoryHint: .notDirectory)
    try Self.zip(folder, to: archive, fileManager: fileManager)
    return DiagnosticsArchive(url: archive, summary: summaryText)
  }

  /// The last part of the app's id, kept to lowercase letters, digits and hyphens.
  static func slug(of app: AppIdentity) -> String {
    let last = app.id.split(separator: ".").last.map(String.init) ?? "app"
    let kept = String(last.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
    return kept.isEmpty ? "app" : kept
  }

  private static func zip(_ folder: URL, to archive: URL, fileManager: FileManager) throws(DiagnosticsError) {
    var coordination: NSError?
    var moved: (any Error)?
    NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zipped in
      do {
        try fileManager.moveItem(at: zipped, to: archive)
      } catch {
        moved = error
      }
    }
    if let failure = coordination ?? moved { throw .zip(failure.localizedDescription) }
  }
}
