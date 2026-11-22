import Foundation
import ShadowAI
import ShadowStore
import ShadowSyncRuntime

#if canImport(UIKit)
  import UIKit
#endif

/// Builds a diagnostics archive on demand: the summary from what the app passed, the app's log lines from this process, both scrubbed, zipped.
struct DiagnosticsBuilder {
  let identity: AppIdentity
  let version: AppVersion
  let sources: DiagnosticsSources?
  let archives: DiagnosticsArchives
  let subsystems: Set<String>
  let log: DiagnosticsLog.Source
  let vaults: URL?
  let capabilities: [String: Bool]
  let system: DiagnosticsSummary.System
  let now: @Sendable () -> Date

  static func live(identity: AppIdentity, version: AppVersion, sources: DiagnosticsSources?) -> DiagnosticsBuilder {
    DiagnosticsBuilder(
      identity: identity, version: version, sources: sources, archives: .live(identity: identity),
      subsystems: Set([identity.id, Bundle.main.bundleIdentifier].compactMap(\.self)), log: DiagnosticsLog.unifiedLog,
      vaults: try? VaultDirectory.default().deletingLastPathComponent(), capabilities: capabilities(in: Bundle.main.infoDictionary), system: system(),
      now: { Date() })
  }

  func build() async throws(DiagnosticsError) -> DiagnosticsArchive {
    let now = now()
    var summary = await summary(at: now)
    let since = now.addingTimeInterval(-DiagnosticsLog.span)
    let read: DiagnosticsLog.Read
    do {
      read = try await Self.readLog(log, subsystems: subsystems, since: since)
      summary.log = DiagnosticsSummary.Log(since: since, entries: read.lines.count, dropped: read.dropped, error: nil)
    } catch {
      read = DiagnosticsLog.Read(lines: [], dropped: 0)
      summary.log = DiagnosticsSummary.Log(since: since, entries: 0, dropped: 0, error: error.code)
    }
    return try await Self.write(summary, read, app: identity, into: archives, at: now)
  }

  func summary(at now: Date) async -> DiagnosticsSummary {
    let sync: DiagnosticsSummary.Sync? = if let runtimes = sources?.sync { await Self.sync(runtimes) } else { nil }
    let ai: DiagnosticsSummary.AI? = if let services = sources?.ai { await Self.ai(services, primary: sources?.primary) } else { nil }
    var registries = sources?.stores.mapValues(\.registry.version) ?? [:]
    if let primary = sources?.primary { registries["main"] = primary.registry.version }
    let bytes: Int? = if let vaults { await Self.size(of: vaults) } else { nil }
    let details = await sources?.summary() ?? [:]
    return DiagnosticsSummary(
      generatedAt: now, app: DiagnosticsSummary.App(id: identity.id, name: identity.displayName, version: version.version, build: version.build),
      system: system, capabilities: capabilities, sync: sync, ai: ai, storage: DiagnosticsSummary.Storage(vaultsBytes: bytes, registryVersions: registries),
      details: details)
  }

  /// The `ShadowCapabilities` Info.plist dictionary as flags: a string counts as set unless it is empty, `NO` or a build variable Xcode left unexpanded.
  nonisolated static func capabilities(in info: [String: Any]?) -> [String: Bool] {
    let signed = info?[SyncCapabilities.infoPlistKey] as? [String: Any] ?? [:]
    var flags = signed.mapValues { value -> Bool in
      switch value {
      case let flag as Bool: flag
      case let text as String: !text.isEmpty && text != "NO" && !text.contains("$(")
      default: true
      }
    }
    flags["cloudKitUsable"] = SyncCapabilities(infoDictionary: info).cloudKit != nil
    return flags
  }

  static func system(locale: Locale = .current, timeZone: TimeZone = .current) -> DiagnosticsSummary.System {
    let process = ProcessInfo.processInfo
    let version = process.operatingSystemVersion
    return DiagnosticsSummary.System(
      os: osName, osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", device: deviceKind, architecture: architecture,
      iOSAppOnMac: process.isiOSAppOnMac, locale: locale.identifier, utcOffsetSeconds: timeZone.secondsFromGMT())
  }

  private static var osName: String {
    #if os(macOS)
      "macOS"
    #elseif os(visionOS)
      "visionOS"
    #else
      "iOS"
    #endif
  }

  private static var deviceKind: String {
    #if os(macOS)
      "mac"
    #elseif canImport(UIKit)
      switch UIDevice.current.userInterfaceIdiom {
      case .phone: "phone"
      case .pad: "pad"
      case .mac: "mac"
      case .vision: "vision"
      default: "other"
      }
    #else
      "other"
    #endif
  }

  private static var architecture: String {
    #if arch(arm64)
      "arm64"
    #elseif arch(x86_64)
      "x86_64"
    #else
      "other"
    #endif
  }

  private static func sync(_ runtimes: SyncRuntimes) async -> DiagnosticsSummary.Sync {
    var named: [(String, SyncRuntime)] = runtimes.runtime.map { [("main", $0)] } ?? []
    for route in runtimes.routed.keys.sorted(by: { $0.name < $1.name }) {
      if let routed = runtimes.routed[route] { named.append((route.name, routed.runtime)) }
    }
    var described: [DiagnosticsSummary.Runtime] = []
    for (store, runtime) in named { described.append(await describe(runtime, store: store)) }
    return DiagnosticsSummary.Sync(status: runtimes.status.diagnosticsCode, canMoveVault: runtimes.canMoveVault, runtimes: described)
  }

  private static func describe(_ runtime: SyncRuntime, store: String) async -> DiagnosticsSummary.Runtime {
    let status = runtime.status
    let reason = status.attentionReason
    let attached = await runtime.attachedLocation
    let record = await runtime.runRecord
    return DiagnosticsSummary.Runtime(
      store: store, status: status.diagnosticsCode, attention: reason?.diagnosticsCode, stops: reason?.stops.diagnosticsCode, failureCode: reason?.failureCode,
      replicasMissingKeys: reason?.replicasMissingKeys, clockSkewSeconds: reason?.clockSkewSeconds, phase: await runtime.currentPhase?.diagnosticsCode,
      provider: attached?.location.kind.rawValue, storageClasses: attached?.classPolicy.diagnosticsCode, runs: record.runs, failedRuns: record.failedRuns,
      consecutiveFailures: record.consecutiveFailures, unsentWrites: record.unsentWrites, lastSucceeded: record.lastSucceeded, lastFailed: record.lastFailed,
      lastFailureCode: record.lastFailureCode)
  }

  private static func ai(_ services: AIServices, primary: VaultStore?) async -> DiagnosticsSummary.AI {
    var keys: [String: String] = [:]
    for provider in ModelProviderKind.allCases {
      do {
        keys[provider.rawValue] = try services.keys.contains(provider) ? "stored" : "none"
      } catch {
        keys[provider.rawValue] = "unavailable"
      }
    }
    let (provider, isDemo) = (services.settings.provider.rawValue, services.isDemo)
    guard let primary else { return DiagnosticsSummary.AI(provider: provider, isDemo: isDemo, keys: keys, consents: nil, consentsError: nil) }
    do {
      let granted = try await services.grantedConsents(in: primary)
      let consents = services.disclosures.map { disclosure in
        DiagnosticsSummary.Consent(
          disclosure: disclosure.id, dataClass: disclosure.dataClass, grantedTo: granted.filter { $0.disclosure == disclosure }.map(\.provider.rawValue).sorted())
      }
      return DiagnosticsSummary.AI(provider: provider, isDemo: isDemo, keys: keys, consents: consents, consentsError: nil)
    } catch {
      return DiagnosticsSummary.AI(provider: provider, isDemo: isDemo, keys: keys, consents: nil, consentsError: error.code)
    }
  }

  @concurrent
  nonisolated private static func size(of directory: URL) async -> Int? {
    totalSize(of: directory)
  }

  nonisolated static func totalSize(of directory: URL) -> Int? {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)),
      let files = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return nil }
    var total = 0
    for case let file as URL in files {
      guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
      total += values.fileSize ?? 0
    }
    return total
  }

  @concurrent
  nonisolated private static func readLog(_ log: DiagnosticsLog.Source, subsystems: Set<String>, since: Date) async throws(DiagnosticsError) -> DiagnosticsLog.Read {
    DiagnosticsLog.lines(of: try log(subsystems, since), subsystems: subsystems, since: since)
  }

  @concurrent
  nonisolated private static func write(
    _ summary: DiagnosticsSummary, _ read: DiagnosticsLog.Read, app: AppIdentity, into archives: DiagnosticsArchives, at now: Date
  ) async throws(DiagnosticsError) -> DiagnosticsArchive {
    try archives.archive(app: app, summary: summary, log: read, at: now)
  }
}
