import Foundation
import ShadowAI
import Testing

@testable import NovelForgeEval

@Suite("Eval command", TestTimeLimit.standard)
struct EvalCommandTests {
  private static let novel = "6f0c4d1e-0000-4000-8000-000000000e01"

  private static func command(_ environment: [String: String] = [:]) -> EvalCommand {
    EvalCommand(environment: environment, liveBackend: EvalBackend.live(environment:))
  }

  @Test func shouldPrintUsageForHelp() async {
    let result = await Self.command().run(["--help"])
    #expect(result.exitCode == 0 && result.standardOutput.hasPrefix("usage: nf-eval") && result.standardError.isEmpty)
  }

  @Test func shouldRefuseAPipelineRunWithoutTheLiveFlag() async {
    for arguments in [["--fixture", "lighthouse"], ["--vault", "/nonexistent/vault.db", "--novel", Self.novel]] {
      let backendCalls = Calls()
      let command = EvalCommand(environment: ["NF_EVAL_PROVIDER": "anthropic", "NF_EVAL_API_KEY": "sk-x"]) { environment throws(EvalError) in
        backendCalls.count += 1
        return try EvalBackend.live(environment: environment)
      }
      let result = await command.run(arguments)
      #expect(result.exitCode == EvalCommand.exitUsage && result.standardOutput.isEmpty && result.standardError.contains("--live"))
      #expect(backendCalls.count == 0)
    }
  }

  @Test func shouldRefuseALiveRunWithoutAConfiguredProvider() async {
    for environment in [[:], ["NF_EVAL_PROVIDER": "anthropic"], ["NF_EVAL_API_KEY": "sk-x"], ["NF_EVAL_PROVIDER": "anthropic", "NF_EVAL_API_KEY": ""]] {
      let result = await Self.command(environment).run(["--fixture", "lighthouse", "--live"])
      #expect(result.exitCode == EvalCommand.exitUsage && result.standardOutput.isEmpty && result.standardError.contains("NF_EVAL_PROVIDER"))
    }
  }

  @Test func shouldRefuseAProviderItCannotRun() async {
    let result = await Self.command(["NF_EVAL_PROVIDER": "openrouter", "NF_EVAL_API_KEY": "sk-x"]).run(["--fixture", "lighthouse", "--live"])
    #expect(result.exitCode == EvalCommand.exitUsage && result.standardError.contains("openrouter"))
  }

  @Test func shouldBuildTheLiveBackendWithoutCallingTheNetwork() throws {
    let backend = try EvalBackend.live(environment: ["NF_EVAL_PROVIDER": "anthropic", "NF_EVAL_API_KEY": "sk-x"])
    #expect(backend.binding.host == "api.anthropic.com")
  }

  @Test func shouldRejectBadArguments() async {
    let cases: [[String]] = [
      [], ["--vault", "x"], ["--vault", "x", "--novel", "not-a-uuid"], ["--fixture", "nope"], ["--fixture", "lighthouse", "--chapters", "0"],
      ["--fixture", "lighthouse", "--live", "--metrics-only"], ["--fixture", "lighthouse", "--live", "--write-vault"], ["--vault", "x", "--novel", Self.novel, "--write-vault"],
      ["--fixture", "lighthouse", "--metrics-only"], ["--fixture", "lighthouse", "--vault", "x"],
      ["--fixture"], ["--bogus"],
    ]
    for arguments in cases {
      let result = await Self.command().run(arguments)
      #expect(result.exitCode == EvalCommand.exitUsage && result.standardOutput.isEmpty && result.standardError.hasPrefix("nf-eval: "), "\(arguments)")
    }
  }

  @Test func shouldRefuseALiveVaultRunWithoutWriteVaultBeforeAnyBackendOrWrite() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("nf-eval-\(UUID().uuidString)/vault.sqlite").path
    let backendCalls = Calls()
    let command = EvalCommand(environment: ["NF_EVAL_PROVIDER": "anthropic", "NF_EVAL_API_KEY": "sk-x"]) { environment throws(EvalError) in
      backendCalls.count += 1
      return try EvalBackend.live(environment: environment)
    }
    let result = await command.run(["--vault", path, "--novel", Self.novel, "--live"])
    #expect(result.exitCode == EvalCommand.exitUsage && result.standardOutput.isEmpty && result.standardError.contains("--write-vault"))
    #expect(backendCalls.count == 0 && !FileManager.default.fileExists(atPath: path))
  }

  @Test func shouldNameTheWritesAndTheOpenRouterRefusalInTheUsage() {
    #expect(EvalArguments.usage.contains("CANNOT BE UNDONE") && EvalArguments.usage.contains("FINALIZES") && EvalArguments.usage.contains("OpenRouter is refused"))
  }
}

private final class Calls: @unchecked Sendable {
  var count = 0
}
