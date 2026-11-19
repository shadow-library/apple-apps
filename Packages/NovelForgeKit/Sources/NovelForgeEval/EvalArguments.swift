import Foundation

enum EvalSource: Equatable {
  case vault(path: String, novel: UUID)
  case fixture(String)
}

struct EvalArguments: Equatable {
  static let fixtures = ["lighthouse"]

  enum Action: Equatable {
    case help
    case run
  }

  let action: Action
  let source: EvalSource?
  let chapters: Int
  let live: Bool
  let metricsOnly: Bool
  let writeVault: Bool
  let priorWindow: Int

  static let usage = """
    usage: nf-eval (--vault <database file> --novel <uuid> | --fixture <name>) [--chapters <n>] [--prior-window <n>] [--live [--write-vault] | --metrics-only]
           nf-eval --help

    --vault           the Novel Forge vault database file
    --novel           the novel to evaluate in the vault
    --fixture         a built-in seed novel in a throwaway in-memory vault: \(fixtures.joined(separator: ", "))
    --chapters        how many chapters to run through plan, generate, review, finalize review, finalize and refresh (default 1)
    --prior-window    how many chapters before each one count toward its cross-chapter n-gram comparison; 0 takes all of them (default 10)
    --live            run the pipelines against a real model; needs NF_EVAL_PROVIDER=anthropic and NF_EVAL_API_KEY in the environment (OpenRouter is refused)
    --write-vault     required with --live --vault. The run WRITES INTO THE REAL VAULT: it applies a plan card, writes a draft, a review and an approval as the
                      author, FINALIZES the chapter and refreshes the Story Bible. Those writes sync to the author's other devices and CANNOT BE UNDONE.
                      The vault must already hold the author's AI consent; nf-eval never records one there.
    --metrics-only    measure the chapters already in the vault; no pipeline runs and no model is called. It still opens the vault read-write, so a vault
                      that needs migrations or projection catch-up is changed by opening it
    """

  init(action: Action, source: EvalSource?, chapters: Int, live: Bool, metricsOnly: Bool, writeVault: Bool = false, priorWindow: Int) {
    self.action = action
    self.source = source
    self.chapters = chapters
    self.live = live
    self.metricsOnly = metricsOnly
    self.writeVault = writeVault
    self.priorWindow = priorWindow
  }

  init(parsing arguments: [String]) throws(EvalError) {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      switch argument {
      case "--help", "-h": flags.insert("help")
      case "--live": flags.insert("live")
      case "--metrics-only": flags.insert("metrics-only")
      case "--write-vault": flags.insert("write-vault")
      case "--vault", "--novel", "--fixture", "--chapters", "--prior-window":
        guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw .usage("missing value for \(argument)") }
        guard values.updateValue(arguments[index], forKey: String(argument.dropFirst(2))) == nil else { throw .usage("\(argument) was given twice") }
        index += 1
      default: throw .usage("unknown argument \(argument)")
      }
    }
    guard !flags.contains("help") else {
      self.init(action: .help, source: nil, chapters: 1, live: false, metricsOnly: false, priorWindow: 10)
      return
    }
    let chapters = try Self.count(values["chapters"], name: "--chapters", default: 1, minimum: 1)
    let priorWindow = try Self.count(values["prior-window"], name: "--prior-window", default: 10, minimum: 0)
    let live = flags.contains("live")
    let metricsOnly = flags.contains("metrics-only")
    let writeVault = flags.contains("write-vault")
    guard !(live && metricsOnly) else { throw .usage("--live and --metrics-only exclude each other") }
    guard !writeVault || (live && values["vault"] != nil) else { throw .usage("--write-vault applies only to --live --vault") }
    let source: EvalSource
    switch (values["vault"], values["fixture"]) {
    case (let path?, nil):
      guard let novel = values["novel"].flatMap({ UUID(uuidString: $0) }) else { throw .usage("--vault needs --novel <uuid>") }
      source = .vault(path: path, novel: novel)
    case (nil, let name?):
      guard Self.fixtures.contains(name) else { throw .usage("unknown fixture \(name); use one of \(Self.fixtures.joined(separator: ", "))") }
      guard values["novel"] == nil else { throw .usage("--novel does not apply to a fixture") }
      guard !metricsOnly else { throw .usage("--metrics-only measures an existing vault; a fixture has no chapters until it runs") }
      source = .fixture(name)
    default: throw .usage("give exactly one of --vault and --fixture")
    }
    self.init(action: .run, source: source, chapters: chapters, live: live, metricsOnly: metricsOnly, writeVault: writeVault, priorWindow: priorWindow)
  }

  private static func count(_ text: String?, name: String, default fallback: Int, minimum: Int) throws(EvalError) -> Int {
    guard let text else { return fallback }
    guard let value = Int(text), value >= minimum else { throw .usage("\(name) must be a whole number of at least \(minimum)") }
    return value
  }
}
