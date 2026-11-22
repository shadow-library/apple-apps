import Foundation

enum CheckError: Error, CustomStringConvertible {
  case unreadable(path: String, reason: String)
  case packageDumpFailed(package: String, output: String)
  case unknownModule(app: String, reference: String)
  case unresolvedModule(String, referencedBy: String)
  case unknownArgument(String)

  var description: String {
    switch self {
    case .unreadable(let path, let reason): "Cannot read \(path): \(reason)"
    case .packageDumpFailed(let package, let output): "swift package dump-package failed for \(package): \(output)"
    case .unknownModule(let app, let reference): "\(app) depends on \(reference), which names no case in SharedModule or ProductModule"
    case .unresolvedModule(let module, let owner): "\(owner) depends on \(module), which no package under Packages/ defines as a target"
    case .unknownArgument(let argument): "Unknown argument \(argument); the only option is --evidence"
    }
  }
}

enum Category: String, CaseIterable {
  case userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"
  case fileTimestamp = "NSPrivacyAccessedAPICategoryFileTimestamp"
  case systemBootTime = "NSPrivacyAccessedAPICategorySystemBootTime"
  case diskSpace = "NSPrivacyAccessedAPICategoryDiskSpace"
  case activeKeyboards = "NSPrivacyAccessedAPICategoryActiveKeyboards"

  var name: String { String(rawValue.dropFirst("NSPrivacyAccessedAPICategory".count)) }

  var reasons: Set<String> {
    switch self {
    case .userDefaults: ["CA92.1", "1C8F.1", "C56D.1", "AC6B.1"]
    case .fileTimestamp: ["DDA9.1", "C617.1", "3B52.1", "0A2A.1"]
    case .systemBootTime: ["35F9.1", "8FFB.1", "3D61.1"]
    case .diskSpace: ["85F4.1", "E174.1", "7D9E.1", "B728.1"]
    case .activeKeyboards: ["3EC4.1", "54BD.1"]
    }
  }

  var patterns: [String] {
    let call = #"(?:^|[^\w.]|Darwin\.)"#
    switch self {
    case .userDefaults:
      return [#"\b(?:UserDefaults|NSUserDefaults|AppStorage)\b"#]
    case .fileTimestamp:
      return [
        call + #"(?:lstat|fstat|fstatat|getattrlist|getattrlistbulk|fgetattrlist|getattrlistat)\s*\("#,
        call + #"stat\s*\(\s*(?:\)|[^():,]+,\s*&)"#,
        #"\bstruct\s+stat\b"#,
        #"\b(?:contentModificationDateKey|creationDateKey|NSURLContentModificationDateKey|NSURLCreationDateKey|NSFileModificationDate|NSFileCreationDate)\b"#,
        #"\.(?:fileModificationDate|fileCreationDate)\b"#,
        #"FileAttributeKey\.(?:creationDate|modificationDate)\b"#,
        #"[\[,]\s*\.(?:creationDate|modificationDate)\s*[\]:]"#,
      ]
    case .systemBootTime:
      return [#"\b(?:systemUptime|mach_absolute_time)\b"#]
    case .diskSpace:
      return [
        #"\b(?:NSURL)?(?:v|V)olume(?:AvailableCapacity|AvailableCapacityForImportantUsage|AvailableCapacityForOpportunisticUsage|TotalCapacity)Key\b"#,
        #"\b(?:NSFileSystemFreeSize|NSFileSystemSize)\b"#,
        #"FileAttributeKey\.(?:systemFreeSize|systemSize)\b"#,
        #"[\[,]\s*\.(?:systemFreeSize|systemSize)\s*[\]:]"#,
        call + #"(?:statfs|statvfs|fstatfs|fstatvfs)\s*\("#,
        #"\bstruct\s+statv?fs\b"#,
      ]
    case .activeKeyboards:
      return [#"\bactiveInputModes\b"#]
    }
  }
}

struct Site: Hashable, Comparable {
  let path: String
  let line: Int

  var description: String { "\(path):\(line)" }

  static func < (lhs: Site, rhs: Site) -> Bool { (lhs.path, lhs.line) < (rhs.path, rhs.line) }
}

struct Dependency {
  let name: String
  let package: String?
}

struct PackageTarget {
  let directory: String
  let dependencies: [Dependency]
}

struct PackageGraph {
  var targets: [String: PackageTarget] = [:]
  var localPackages: Set<String> = []
}

struct AppReport {
  let name: String
  let modules: [String]
  let thirdParty: [String]
  let uses: [Category: [Site]]
  let problems: [String]
}

let sourceExtensions: Set<String> = ["swift", "m", "mm", "c", "cc", "cpp", "h"]
let manifestPath = "Resources/PrivacyInfo.xcprivacy"

func read(_ url: URL) throws(CheckError) -> String {
  do {
    return try String(contentsOf: url, encoding: .utf8)
  } catch {
    throw .unreadable(path: url.path, reason: error.localizedDescription)
  }
}

func expression(_ pattern: String) -> NSRegularExpression {
  guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { preconditionFailure("invalid pattern \(pattern)") }
  return expression
}

let categoryExpressions = Category.allCases.map { category in (category, category.patterns.map(expression)) }

func matches(_ pattern: String, in text: String) -> [[String]] {
  let range = NSRange(text.startIndex..., in: text)
  return expression(pattern).matches(in: text, range: range).map { match in
    (0..<match.numberOfRanges).map { index in Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
  }
}

func moduleCases(root: URL) throws(CheckError) -> [String: String] {
  var cases: [String: String] = [:]
  for (kind, file) in [("shared", "SharedModule.swift"), ("product", "ProductModule.swift")] {
    let text = try read(root.appending(path: "Tuist/ProjectDescriptionHelpers/\(file)"))
    for match in matches(#"case\s+(\w+)\s*=\s*"(\w+)""#, in: text) { cases["\(kind).\(match[1])"] = match[2] }
  }
  return cases
}

func directDependencies(of app: String, manifest: String, cases: [String: String]) throws(CheckError) -> [String] {
  guard let start = manifest.range(of: #"(?<!\w)dependencies:\s*\["#, options: .regularExpression) else { return [] }
  var depth = 1
  var end = start.upperBound
  while end < manifest.endIndex, depth > 0 {
    if manifest[end] == "[" { depth += 1 }
    if manifest[end] == "]" { depth -= 1 }
    end = manifest.index(after: end)
  }
  var modules: [String] = []
  for match in matches(#"\.(shared|product)\(\s*\.(\w+)\s*\)"#, in: String(manifest[start.upperBound..<end])) {
    guard let module = cases["\(match[1]).\(match[2])"] else { throw .unknownModule(app: app, reference: ".\(match[1])(.\(match[2]))") }
    modules.append(module)
  }
  return modules
}

func packageGraph(root: URL) throws(CheckError) -> PackageGraph {
  let manager = FileManager.default
  let packages = root.appending(path: "Packages")
  let names = ((try? manager.contentsOfDirectory(atPath: packages.path)) ?? []).filter { manager.fileExists(atPath: packages.appending(path: "\($0)/Package.swift").path) }
  let scratch = manager.temporaryDirectory.appending(path: "check-privacy-manifests-\(UUID().uuidString)")
  defer { try? manager.removeItem(at: scratch) }
  var graph = PackageGraph()
  for name in names.sorted() {
    let json = try dumpPackage(packages.appending(path: name), scratch: scratch.appending(path: name))
    graph.localPackages.insert(name.lowercased())
    if let declared = json["name"] as? String { graph.localPackages.insert(declared.lowercased()) }
    for entry in json["targets"] as? [[String: Any]] ?? [] where entry["type"] as? String == "regular" {
      guard let target = entry["name"] as? String else { continue }
      let path = entry["path"] as? String ?? "Sources/\(target)"
      let dependencies = (entry["dependencies"] as? [[String: Any]] ?? []).compactMap(dependency)
      graph.targets[target] = PackageTarget(directory: "Packages/\(name)/\(path)", dependencies: dependencies)
    }
  }
  return graph
}

func dumpPackage(_ package: URL, scratch: URL) throws(CheckError) -> [String: Any] {
  let name = package.lastPathComponent
  let log = scratch.appending(path: "dump-package.log")
  let output = Pipe()
  let process = Process()
  process.executableURL = URL(filePath: "/usr/bin/env")
  process.arguments = ["swift", "package", "--package-path", package.path, "--scratch-path", scratch.path, "dump-package"]
  process.standardOutput = output
  do {
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw CheckError.packageDumpFailed(package: name, output: "cannot create \(log.path)") }
    process.standardError = try FileHandle(forWritingTo: log)
    try process.run()
  } catch {
    throw .packageDumpFailed(package: name, output: "\(error)")
  }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw .packageDumpFailed(package: name, output: (try? String(contentsOf: log, encoding: .utf8)) ?? "exit status \(process.terminationStatus)")
  }
  return json
}

func dependency(_ entry: [String: Any]) -> Dependency? {
  if let product = entry["product"] as? [Any], let name = product.first as? String {
    return Dependency(name: name, package: product.dropFirst().first as? String)
  }
  guard let name = ((entry["byName"] ?? entry["target"]) as? [Any])?.first as? String else { return nil }
  return Dependency(name: name, package: nil)
}

func closure(of app: String, direct: [String], in graph: PackageGraph) throws(CheckError) -> (modules: [String], thirdParty: [String]) {
  var seen: Set<String> = []
  var thirdParty: Set<String> = []
  var queue = direct.map { (dependency: Dependency(name: $0, package: nil), owner: app) }
  while let (dependency, owner) = queue.popLast() {
    guard !seen.contains(dependency.name) else { continue }
    guard let target = graph.targets[dependency.name] else {
      guard let package = dependency.package, !graph.localPackages.contains(package.lowercased()) else {
        throw .unresolvedModule(dependency.name, referencedBy: owner)
      }
      thirdParty.insert(dependency.name)
      continue
    }
    seen.insert(dependency.name)
    queue.append(contentsOf: target.dependencies.map { ($0, dependency.name) })
  }
  return (seen.sorted(), thirdParty.sorted())
}

struct StringLiteral {
  let multiline: Bool
  let hashes: Int

  var closer: String { (multiline ? #"""""# : #"""#) + String(repeating: "#", count: hashes) }

  static func opening(_ rest: Substring) -> (literal: StringLiteral, length: Int)? {
    let hashes = rest.prefix { $0 == "#" }.count
    let quotes = rest.dropFirst(hashes)
    guard quotes.hasPrefix(#"""#) else { return nil }
    let multiline = quotes.hasPrefix(#"""""#)
    return (StringLiteral(multiline: multiline, hashes: hashes), hashes + (multiline ? 3 : 1))
  }
}

struct CommentStripper {
  private var depth = 0
  private var string: StringLiteral?

  mutating func code(in line: String) -> String {
    var code = ""
    var escaped = false
    var index = line.startIndex
    func take(_ count: Int) {
      let end = line.index(index, offsetBy: count)
      code += line[index..<end]
      index = end
    }
    while index < line.endIndex {
      let rest = line[index...]
      if depth > 0 {
        if rest.hasPrefix("/*") || rest.hasPrefix("*/") {
          depth += rest.hasPrefix("/*") ? 1 : -1
          index = line.index(index, offsetBy: 2)
        } else {
          index = line.index(after: index)
        }
      } else if let literal = string {
        if escaped {
          escaped = false
        } else if literal.hashes == 0, rest.hasPrefix("\\") {
          escaped = true
        } else if rest.hasPrefix(literal.closer) {
          string = nil
          take(literal.closer.count)
          continue
        }
        take(1)
      } else if rest.hasPrefix("/*") {
        depth += 1
        index = line.index(index, offsetBy: 2)
      } else if rest.hasPrefix("//") {
        break
      } else if let opening = StringLiteral.opening(rest) {
        string = opening.literal
        take(opening.length)
      } else {
        take(1)
      }
    }
    if string?.multiline == false { string = nil }
    return code
  }
}

func scan(_ directory: String, root: URL, into uses: inout [Category: Set<Site>]) throws(CheckError) {
  let base = root.appending(path: directory)
  guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return }
  for case let url as URL in enumerator where sourceExtensions.contains(url.pathExtension) {
    let relative = directory + url.path.dropFirst(base.path.count)
    var comments = CommentStripper()
    for (number, line) in try read(url).components(separatedBy: "\n").enumerated() {
      let code = comments.code(in: line)
      let range = NSRange(code.startIndex..., in: code)
      for (category, patterns) in categoryExpressions where patterns.contains(where: { $0.firstMatch(in: code, range: range) != nil }) {
        uses[category, default: []].insert(Site(path: relative, line: number + 1))
      }
    }
  }
}

func declarations(in url: URL) -> (declared: [Category: [String]], problems: [String]) {
  guard let data = try? Data(contentsOf: url) else { return ([:], []) }
  guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
    return ([:], ["\(manifestPath) is not a property list dictionary"])
  }
  var problems: [String] = []
  if !(plist["NSPrivacyTracking"] is Bool) { problems.append("NSPrivacyTracking must be a Boolean") }
  for key in ["NSPrivacyTrackingDomains", "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"] where !(plist[key] is [Any]) {
    problems.append("\(key) must be an array")
  }
  var declared: [Category: [String]] = [:]
  for entry in plist["NSPrivacyAccessedAPITypes"] as? [Any] ?? [] {
    guard let entry = entry as? [String: Any], let type = entry["NSPrivacyAccessedAPIType"] as? String, let category = Category(rawValue: type) else {
      problems.append("NSPrivacyAccessedAPITypes has an entry with an unknown or missing NSPrivacyAccessedAPIType")
      continue
    }
    guard declared[category] == nil else {
      problems.append("\(category.name) is declared twice")
      continue
    }
    let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
    if reasons.isEmpty { problems.append("\(category.name) declares no reason") }
    for reason in reasons where !category.reasons.contains(reason) { problems.append("\(reason) is not a reason Apple defines for \(category.name)") }
    declared[category] = reasons
  }
  return (declared, problems)
}

func report(app: String, root: URL, cases: [String: String], graph: PackageGraph) throws(CheckError) -> AppReport {
  let folder = "Apps/\(app)"
  let direct = try directDependencies(of: app, manifest: try read(root.appending(path: "\(folder)/Project.swift")), cases: cases)
  let linked = try closure(of: app, direct: direct, in: graph)
  var found: [Category: Set<Site>] = [:]
  try scan("\(folder)/Sources", root: root, into: &found)
  for directory in linked.modules.compactMap({ graph.targets[$0]?.directory }) { try scan(directory, root: root, into: &found) }
  let uses = found.mapValues { $0.sorted() }

  let manifest = root.appending(path: "\(folder)/\(manifestPath)")
  let exists = FileManager.default.fileExists(atPath: manifest.path)
  let (declared, declarationProblems) = declarations(in: manifest)
  var problems = declarationProblems
  if !exists, !uses.isEmpty { problems.append("uses required-reason APIs but has no \(manifestPath)") }
  for category in Category.allCases {
    let sites = uses[category] ?? []
    if exists, !sites.isEmpty, declared[category] == nil {
      problems.append("uses \(category.name) but its manifest does not declare it, at \(sites.prefix(3).map(\.description).joined(separator: ", "))")
    }
    if sites.isEmpty, declared[category] != nil {
      problems.append("declares \(category.name), which neither its sources nor the modules it links use")
    }
  }
  return AppReport(name: app, modules: linked.modules, thirdParty: linked.thirdParty, uses: uses, problems: problems)
}

func evidence(_ reports: [AppReport]) -> String {
  var rows: [String: (category: String, site: Site, apps: [String])] = [:]
  for report in reports {
    for (category, sites) in report.uses {
      for site in sites { rows["\(category.name) \(site)", default: (category.name, site, [])].apps.append(report.name) }
    }
  }
  let ordered = rows.values.sorted { ($0.category, $0.site) < ($1.category, $1.site) }
  let lines = ordered.map { row in "| \(row.category) | `\(row.site.description)` | \(row.apps.sorted().joined(separator: ", ")) |" }
  return (["| Category | Site | Linked by |", "| --- | --- | --- |"] + lines).joined(separator: "\n")
}

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

do {
  let arguments = CommandLine.arguments.dropFirst()
  if let unknown = arguments.first(where: { $0 != "--evidence" }) { throw CheckError.unknownArgument(unknown) }
  let cases = try moduleCases(root: root)
  let graph = try packageGraph(root: root)
  let apps = ((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Apps").path)) ?? [])
    .filter { FileManager.default.fileExists(atPath: root.appending(path: "Apps/\($0)/Project.swift").path) }
    .sorted()
  var reports: [AppReport] = []
  for app in apps { reports.append(try report(app: app, root: root, cases: cases, graph: graph)) }

  if arguments.contains("--evidence") {
    print(evidence(reports))
    exit(0)
  }
  for report in reports {
    let used = Category.allCases.compactMap { category in report.uses[category].map { "\(category.name) (\($0.count))" } }
    print("\(report.name): \(used.isEmpty ? "no required-reason API" : used.joined(separator: ", "))")
    if !report.thirdParty.isEmpty { print("  third-party modules, covered by their own manifests: \(report.thirdParty.joined(separator: ", "))") }
  }
  let problems = reports.flatMap { report in report.problems.map { "\(report.name): \($0)" } }
  guard problems.isEmpty else {
    FileHandle.standardError.write(Data((problems.map { "error: \($0)" } + [""]).joined(separator: "\n").utf8))
    exit(1)
  }
} catch {
  FileHandle.standardError.write(Data("check-privacy-manifests: \(error)\n".utf8))
  exit(1)
}
