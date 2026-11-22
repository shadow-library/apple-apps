import ShadowStore
import SwiftUI

/// A value an app adds to the diagnostics summary: a count, a flag or a code it chose, never text the owner wrote or a name the owner gave.
public nonisolated enum DiagnosticsValue: Sendable, Equatable, Encodable {
  case count(Int)
  case flag(Bool)
  case code(String)
  case group([String: DiagnosticsValue])

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .count(let count): try container.encode(count)
    case .flag(let flag): try container.encode(flag)
    case .code(let code): try container.encode(code)
    case .group(let group): try container.encode(group)
    }
  }
}

/// What the app hands the diagnostics report: its sync runtimes, its AI services, its stores (`primary` holds the AI consents) and a summary of its own
/// work. Every part is optional; a part left out is reported as absent.
public struct DiagnosticsSources {
  public typealias Summary = @Sendable () async -> [String: DiagnosticsValue]

  let sync: SyncRuntimes?
  let ai: AIServices?
  let primary: VaultStore?
  let stores: [String: VaultStore]
  let summary: Summary

  public init(
    sync: SyncRuntimes? = nil, ai: AIServices? = nil, primary: VaultStore? = nil, stores: [String: VaultStore] = [:], summary: @escaping Summary = { [:] }
  ) {
    self.sync = sync
    self.ai = ai
    self.primary = primary
    self.stores = stores
    self.summary = summary
  }
}

extension EnvironmentValues {
  @Entry var diagnosticsSources: DiagnosticsSources?
}

extension View {
  /// Every About screen inside this view offers Share Diagnostics, built from `sources`.
  public func diagnostics(_ sources: DiagnosticsSources?) -> some View {
    environment(\.diagnosticsSources, sources)
  }
}
