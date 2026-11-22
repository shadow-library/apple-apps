import Foundation
import OSLog
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import Testing

@testable import ShadowAppShell

@Suite("Diagnostics scrub", TestTimeLimit.quick)
struct DiagnosticsScrubTests {
  @Test("should replace seeded bearer tokens, API keys, access key ids, long secrets, email addresses and home folders")
  func shouldReplaceSeededSecrets() {
    let seeded = [
      "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N",
      "key=sk-ant-api03-Qx7vT2mLp9RkW4zY8nB1cD6eF0gH3jK5",
      "openrouter sk-or-v1-0f4c2e9b7a1d3c5e8f6a0b2d4c6e8f0a",
      "id AKIAIOSFODNN7EXAMPLE used",
      "secret wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY end",
      "mail leander.paul+notes@example-mail.co.uk now",
      "path /Users/leander/Library/Application Support/x",
    ]

    let scrubbed = DiagnosticsScrub.apply(seeded.joined(separator: "\n"))

    for secret in [
      "eyJhbGciOiJIUzI1NiJ9", "Qx7vT2mLp9RkW4zY8nB1cD6eF0gH3jK5", "0f4c2e9b7a1d3c5e8f6a0b2d4c6e8f0a", "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI", "leander.paul",
      "example-mail", "/Users/leander",
    ] {
      #expect(!scrubbed.contains(secret), "\(secret) survived")
    }
    #expect(scrubbed.contains("Authorization: Bearer <redacted>"))
    #expect(scrubbed.contains("path /Users/<redacted>/Library/Application Support/x"))
    #expect(scrubbed.contains("id <redacted> used"))
  }

  @Test("should leave log text, codes, dates, identifiers and JSON alone")
  func shouldLeaveOrdinaryTextAlone() {
    let ordinary = """
      2026-11-23T10:15:02.123Z error [sync] Sync call failed code=sync.storage.unavailable
      task-scheduler ran 3 jobs; replica 019a4c1e-7b2d-7c3e-9f10-2a3b4c5d6e7f is up to date
      {"format": "com.shadow.library.shadowappshell.diagnostics", "consecutiveFailures": 0, "registryVersions": {"main": 4}}
      AnExtremelyLongIdentifierWithoutDigitsThatStaysReadable
      """

    #expect(DiagnosticsScrub.apply(ordinary) == ordinary)
  }
}

@Suite("Diagnostics log", TestTimeLimit.quick)
struct DiagnosticsLogTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private static func entry(_ subsystem: String, _ text: String, at date: Date = now, category: String = "sync") -> DiagnosticsLogEntry {
    DiagnosticsLogEntry(date: date, level: "error", subsystem: subsystem, category: category, pieces: [.init(text: text, placeholder: "", argument: .none)])
  }

  @Test("should keep only the app's subsystems and the last day's entries, the latest of them when there are too many")
  func shouldFilterToTheSubsystemAndSpan() {
    let since = Self.now.addingTimeInterval(-DiagnosticsLog.span)
    let entries = [
      Self.entry("com.shadow.apps.shelltest", "too old", at: since.addingTimeInterval(-1)),
      Self.entry("com.apple.network", "another subsystem"),
      Self.entry("com.shadow.apps.shelltest", "first"),
      Self.entry("com.shadow.apps.shelltestx", "a lookalike subsystem"),
      Self.entry("com.shadow.apps.shelltest", "second"),
      Self.entry("com.shadow.library.shadowkit", "the shell's fallback"),
      Self.entry("com.shadow.apps.shelltest", "third"),
    ]

    let all = DiagnosticsLog.lines(of: entries, subsystems: ["com.shadow.apps.shelltest"], since: since)
    let latest = DiagnosticsLog.lines(of: entries, subsystems: ["com.shadow.apps.shelltest"], since: since, limit: 2)

    #expect(all.lines.map { $0.components(separatedBy: "] ").last } == ["first", "second", "third"])
    #expect(all.dropped == 0)
    #expect(latest.lines.map { $0.components(separatedBy: "] ").last } == ["second", "third"])
    #expect(latest.dropped == 1)
    #expect(all.lines.first == "2027-01-15T08:00:00.000Z error [sync] first")
  }

  @Test("should keep an entry the log handed back twice once, and the same words logged again")
  func shouldKeepARepeatedEntryOnce() {
    let since = Self.now.addingTimeInterval(-60)
    let entries = [
      Self.entry("s", "once"), Self.entry("s", "once"), Self.entry("s", "once", at: Self.now.addingTimeInterval(1)), Self.entry("s", "once", category: "jobs"),
    ]

    let read = DiagnosticsLog.lines(of: entries, subsystems: ["s"], since: since)

    #expect(read.lines.count == 3, "\(read.lines)")
    #expect(read.dropped == 0)
  }

  @Test("should show public values and unannotated numbers, and hide every other value")
  func shouldRenderOnlyWhatItsPlaceholderAllows() {
    let pieces: [DiagnosticsLogEntry.Piece] = [
      .init(text: "public ", placeholder: "%{public}s", argument: .text("code.public")),
      .init(text: " auto ", placeholder: "%s", argument: .text("Ashfall chapter")),
      .init(text: " private ", placeholder: "%{private}s", argument: .text("Marigold")),
      .init(text: " sensitive ", placeholder: "%{sensitive, public}s", argument: .text("Juniper")),
      .init(text: " masked ", placeholder: "%{private, mask.hash}s", argument: .text("Lantern")),
      .init(text: " count ", placeholder: "%ld", argument: .number("42")),
      .init(text: " hidden count ", placeholder: "%{private}ld", argument: .number("7")),
      .init(text: " redacted ", placeholder: "%{public}s", argument: .text(nil)),
      .init(text: " data ", placeholder: "%{public}@", argument: .undecodable),
      .init(text: " 100%% done", placeholder: "", argument: .none),
    ]

    let message = DiagnosticsLogEntry(date: Self.now, level: "info", subsystem: "s", category: "c", pieces: pieces).message

    #expect(
      message
        == "public code.public auto <private> private <private> sensitive <private> masked <private> count 42 hidden count <private> redacted <private> data <private> 100% done"
    )
  }

  @Test("should cut an overlong line")
  func shouldCutAnOverlongLine() {
    let line = DiagnosticsLog.line(Self.entry("s", String(repeating: "a", count: DiagnosticsLog.lineLimit * 2)))

    #expect(line.count == DiagnosticsLog.lineLimit + 1)
    #expect(line.hasSuffix("…"))
  }

  @Test("should read this process's lines of one subsystem from the unified log with private values hidden")
  func shouldReadThisProcesssLinesFromTheUnifiedLog() async throws {
    let subsystem = "com.shadow.apps.shelltest.log-\(UUID().uuidString.lowercased())"
    let since = Date().addingTimeInterval(-60)
    let secret = "Marigold Cipher"
    Logger(subsystem: subsystem, category: "probe").error("Probe private=\(secret, privacy: .private) code=\("probe.code", privacy: .public) count=\(3)")
    Logger(subsystem: "\(subsystem).other", category: "probe").error("Other subsystem \("must not appear", privacy: .public)")

    let read = try await DiagnosticsWorld.logLines(subsystems: [subsystem], since: since) { !$0.isEmpty }

    #expect(!read.lines.isEmpty)
    for line in read.lines {
      #expect(line.hasSuffix("error [probe] Probe private=<private> code=probe.code count=3"), "\(read.lines)")
      #expect(!line.contains("Marigold"), "\(read.lines)")
    }
  }
}

@MainActor
@Suite("Diagnostics archive", TestTimeLimit.standard)
struct DiagnosticsArchiveTests {
  @Test("should hold no content, key, location, device name or private log value, and describe sync, AI and the stores")
  func shouldHoldNoContent() async throws {
    let distinctive = DiagnosticsWorld.Distinctive()
    let world = try DiagnosticsWorld(storageName: distinctive.folder)
    defer { world.remove() }
    let (store, runtimes) = try await world.attached()
    try await SyncWorld.writeNote(distinctive.note, in: store)
    try await SyncWorld.until("the note is uploaded") { try await SyncWorld.isUploaded(store) && runtimes.status == .upToDate }
    let ai = try SettingsFixtures.world()
    defer { ai.tearDown() }
    try ai.services.keys.save(try #require(ai.services.keys.makeCredential(distinctive.apiKey, for: .anthropic)), for: .anthropic)
    try await ai.services.grant(
      AIConsentRequest(provider: .anthropic, host: "api.anthropic.com", dataClass: "fixture-text", disclosure: "fixture-text/v2"), in: store)
    let side = try ShellStore.open()
    try await ShellStore.writeNote(distinctive.sideNote, in: side)
    try Data(distinctive.note.utf8).write(to: world.vaults.appending(path: "\(distinctive.fileName).txt"))
    Logger(subsystem: world.subsystem, category: "probe").error(
      "Opened \(distinctive.note, privacy: .private) for \(distinctive.email, privacy: .public) with \(distinctive.apiKey, privacy: .public)")
    _ = try await DiagnosticsWorld.logLines(subsystems: [world.subsystem], since: Date().addingTimeInterval(-60)) { !$0.isEmpty }
    let sources = DiagnosticsSources(
      sync: runtimes, ai: ai.services, primary: store, stores: ["side": side], summary: { ["jobs": .group(["queued": .count(2)]), "replay": .code("v5")] })

    let vault = try #require(await runtimes.runtime?.attachedLocation?.location.vault)

    let archive = try await world.builder(sources: sources).build()
    await runtimes.shutDown()

    let contents = try DiagnosticsWorld.unzipped(archive.url)
    let identifiers = [vault.description, store.replica.description, store.replica.uuid.uuidString, side.replica.description]
    for secret in distinctive.all + identifiers + [SyncWorld.device.name, world.folder.path(percentEncoded: false)] {
      #expect(!contents.contains(secret), "\(secret) is in the archive")
    }
    let summary = try #require(try JSONSerialization.jsonObject(with: Data(archive.summary.utf8)) as? [String: Any])
    let sync = try #require(summary["sync"] as? [String: Any])
    let main = try #require((sync["runtimes"] as? [[String: Any]])?.first)
    #expect(main["store"] as? String == "main")
    #expect(main["provider"] as? String == "localFolder")
    #expect(main["phase"] as? String == "vault.ready")
    #expect((main["runs"] as? Int ?? 0) > 0)
    let aiSummary = try #require(summary["ai"] as? [String: Any])
    #expect((aiSummary["keys"] as? [String: String])?["anthropic"] == "stored")
    #expect(aiSummary["isDemo"] as? Bool == false)
    let consent = try #require((aiSummary["consents"] as? [[String: Any]])?.first)
    #expect(consent["disclosure"] as? String == "fixture-text/v2")
    #expect(consent["grantedTo"] as? [String] == ["anthropic"])
    let storage = try #require(summary["storage"] as? [String: Any])
    #expect(storage["registryVersions"] as? [String: Int] == ["main": 1, "side": 1])
    #expect((storage["vaultsBytes"] as? Int ?? 0) > 0)
    #expect((summary["details"] as? [String: Any])?["replay"] as? String == "v5")
    #expect(contents.contains("Opened <private> for <redacted> with <redacted>"))
    #expect(contents.contains("\"app\""))
  }

  @Test("should report an unreadable log in the summary and still build the archive")
  func shouldReportAnUnreadableLog() async throws {
    let world = try DiagnosticsWorld(storageName: "Storage")
    defer { world.remove() }

    let archive = try await world.builder(sources: nil, log: { (_, _) throws(DiagnosticsError) -> [DiagnosticsLogEntry] in throw .logUnavailable("refused") }).build()

    let summary = try #require(try JSONSerialization.jsonObject(with: Data(archive.summary.utf8)) as? [String: Any])
    #expect((summary["log"] as? [String: Any])?["error"] as? String == "diagnostics.log_unavailable")
    #expect(summary["sync"] == nil)
    #expect(FileManager.default.fileExists(atPath: archive.url.path(percentEncoded: false)))
  }

  @Test("should keep one archive waiting, and remove it on clear, when the screen goes away and at launch")
  func shouldKeepOneArchiveAndRemoveIt() async throws {
    let world = try DiagnosticsWorld(storageName: "Storage")
    defer { world.remove() }
    let model = DiagnosticsModel(builder: world.builder(sources: nil, log: { _, _ in [] }))

    await model.prepare()
    let first = try #require(model.file?.url)
    await model.prepare()
    #expect(try FileManager.default.contentsOfDirectory(atPath: world.archives.path(percentEncoded: false)) == [first.lastPathComponent])
    model.clear()
    #expect(model.stage == .idle)
    #expect(!FileManager.default.fileExists(atPath: world.archives.path(percentEncoded: false)))

    await model.prepare()
    model.disappeared()
    #expect(model.file == nil)
    #expect(!FileManager.default.fileExists(atPath: world.archives.path(percentEncoded: false)))

    let identity = AppIdentity(
      id: "com.shadow.apps.shelltest.leftovers-\(UUID().uuidString.lowercased())", displayName: "Leftovers", vaultNoun: "library", vaultTitle: "Library",
      exampleBucketName: "my-notes")
    let leftovers = DiagnosticsArchives.live(identity: identity).directory
    try FileManager.default.createDirectory(at: leftovers, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: leftovers.appending(path: "old.zip"))
    DiagnosticsArchives.clearLeftovers(identity: identity)
    #expect(!FileManager.default.fileExists(atPath: leftovers.path(percentEncoded: false)))
  }

  @Test("should remove an archive that finishes after the screen went away")
  func shouldRemoveAnArchiveFinishedAfterTheScreenWentAway() async throws {
    let world = try DiagnosticsWorld(storageName: "Storage")
    defer { world.remove() }
    let model = DiagnosticsModel(
      builder: world.builder(
        sources: nil,
        log: { _, _ in
          Thread.sleep(forTimeInterval: 0.3)
          return []
        }))

    let preparing = Task { await model.prepare() }
    try await ShellWait.until("the archive is being prepared") { model.stage == .preparing }
    model.disappeared()
    await preparing.value

    #expect(model.stage == .idle)
    #expect(!FileManager.default.fileExists(atPath: world.archives.path(percentEncoded: false)))
  }

  @Test("should read capability flags, counting a string as set unless it is empty, NO or unexpanded")
  func shouldReadCapabilityFlags() {
    let info: [String: Any] = [
      SyncCapabilities.infoPlistKey: [
        "CloudKitContainer": "iCloud.com.shadow.apps.shelltest", "PushNotifications": true, "SharedKeychainGroup": "$(AppIdentifierPrefix)com.shadow.apps.shared",
        "HealthKit": "NO", "Camera": "",
      ]
    ]

    #expect(
      DiagnosticsBuilder.capabilities(in: info) == [
        "CloudKitContainer": true, "PushNotifications": true, "SharedKeychainGroup": false, "HealthKit": false, "Camera": false, "cloudKitUsable": true,
      ])
    #expect(DiagnosticsBuilder.capabilities(in: nil) == ["cloudKitUsable": false])
  }
}

/// A sync world whose storage folder, vaults directory and archives live under one temporary directory, and a log subsystem of its own.
@MainActor
struct DiagnosticsWorld {
  struct Distinctive {
    let note = "Velvet Thunder Almanac"
    let sideNote = "Obsidian Lighthouse Ledger"
    let folder = "Quillmoor-Orchard"
    let fileName = "Saffron-Weathervane"
    let apiKey = "sk-ant-api03-Zephyr9Kestrel7Tundra5Mosaic3Harbor1"
    let email = "wren.ashdown@example.org"

    var all: [String] { [note, sideNote, folder, fileName, apiKey, "Zephyr9Kestrel", email, "wren.ashdown"] }
  }

  let sync: SyncWorld
  let subsystem = "com.shadow.apps.shelltest.diagnostics-\(UUID().uuidString.lowercased())"

  init(storageName: String) throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "ShadowAppShellDiagnosticsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    sync = try SyncWorld(storage: base.appending(path: storageName, directoryHint: .isDirectory))
    try FileManager.default.createDirectory(at: vaults, withIntermediateDirectories: true)
  }

  var folder: URL { sync.folder }
  var vaults: URL { sync.directory.appending(path: "Vaults", directoryHint: .isDirectory) }
  var archives: URL { sync.directory.appending(path: "Diagnostics", directoryHint: .isDirectory) }

  func attached() async throws -> (VaultStore, SyncRuntimes) {
    let runtimes = sync.runtimes()
    let (store, clock) = try SyncWorld.openStore()
    await runtimes.launch(store, trustedClock: clock)
    let runtime = try #require(runtimes.runtime)
    #expect(try await runtime.attach(sync.settings, choice: .create).canSync)
    try await SyncWorld.until("the attached vault is up to date") { runtimes.status == .upToDate }
    return (store, runtimes)
  }

  func builder(sources: DiagnosticsSources?, log: DiagnosticsLog.Source? = nil) -> DiagnosticsBuilder {
    DiagnosticsBuilder(
      identity: .fixture, version: AppVersion(version: "1.0", build: "7"), sources: sources, archives: DiagnosticsArchives(directory: archives),
      subsystems: [subsystem], log: log ?? DiagnosticsLog.unifiedLog, vaults: vaults, capabilities: [:], system: DiagnosticsBuilder.system(), now: { Date() })
  }

  func remove() {
    sync.remove()
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
  }

  /// The unified log may show a line a moment after it was written.
  nonisolated static func logLines(subsystems: Set<String>, since: Date, until ready: ([String]) -> Bool) async throws -> DiagnosticsLog.Read {
    var read = DiagnosticsLog.Read(lines: [], dropped: 0)
    for _ in 0..<100 {
      read = DiagnosticsLog.lines(of: try DiagnosticsLog.unifiedLog(subsystems, since), subsystems: subsystems, since: since)
      if ready(read.lines) { return read }
      try await Task.sleep(for: .milliseconds(50))
    }
    return read
  }

  nonisolated static func unzipped(_ archive: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(filePath: "/usr/bin/unzip")
    process.arguments = ["-p", archive.path(percentEncoded: false)]
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return String(decoding: data, as: UTF8.self)
  }
}
