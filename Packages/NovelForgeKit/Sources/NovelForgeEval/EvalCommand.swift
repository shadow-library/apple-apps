import Foundation
import NovelForgeCore
import ShadowStore

struct EvalCommandResult: Equatable {
  let exitCode: Int32
  let standardOutput: String
  let standardError: String
}

struct EvalCommand: Sendable {
  typealias LiveBackend = @Sendable ([String: String]) throws(EvalError) -> EvalBackend

  static let exitUsage: Int32 = 64

  let environment: [String: String]
  let liveBackend: LiveBackend

  init(environment: [String: String], liveBackend: @escaping LiveBackend = EvalBackend.live(environment:)) {
    self.environment = environment
    self.liveBackend = liveBackend
  }

  func run(_ arguments: [String]) async -> EvalCommandResult {
    do {
      let parsed = try EvalArguments(parsing: arguments)
      guard parsed.action == .run, let source = parsed.source else { return EvalCommandResult(exitCode: 0, standardOutput: EvalArguments.usage + "\n", standardError: "") }
      let report = try await evaluate(parsed, source: source)
      return EvalCommandResult(exitCode: report.passed ? 0 : 1, standardOutput: report.json.pretty + "\n", standardError: "")
    } catch let error as EvalError {
      return EvalCommandResult(exitCode: Self.exitUsage, standardOutput: "", standardError: "nf-eval: \(error.errorDescription ?? error.code)\n")
    } catch {
      return EvalCommandResult(exitCode: 1, standardOutput: "", standardError: "nf-eval: \(EvalRunner.code(error))\n")
    }
  }

  private func evaluate(_ arguments: EvalArguments, source: EvalSource) async throws(EvalError) -> EvalReport {
    if arguments.metricsOnly {
      guard case .vault(let path, let novel) = source else { throw .usage("--metrics-only measures an existing vault") }
      return try await EvalMeasurement.report(store: try Self.open(path), novel: novel, steps: [], priorWindow: arguments.priorWindow)
    }
    guard arguments.live else { throw .liveRunNotConfirmed }
    if case .vault = source, !arguments.writeVault { throw .writeVaultNotConfirmed }
    let backend = try liveBackend(environment)
    switch source {
    case .vault(let path, let novel):
      return try await EvalRunner(store: try Self.open(path), backend: backend, consent: .require).run(
        novel: novel, chapters: arguments.chapters, priorWindow: arguments.priorWindow)
    case .fixture:
      let store = try Self.open(nil)
      try await EvalFixture.seed(in: store)
      return try await EvalRunner(store: store, backend: backend, consent: .record).run(novel: EvalFixture.novel, chapters: arguments.chapters, priorWindow: arguments.priorWindow)
    }
  }

  private static func open(_ path: String?) throws(EvalError) -> VaultStore {
    do {
      guard let path else { return try NovelForgeStore.openInMemory() }
      return try NovelForgeStore.open(at: URL(fileURLWithPath: path))
    } catch {
      throw .vault(error.code)
    }
  }
}
