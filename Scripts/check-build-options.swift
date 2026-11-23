import Foundation

let optionKeys = ["TUIST_DEVELOPMENT_TEAM", "TUIST_UNRESTRICTED", "TUIST_USES_NON_EXEMPT_ENCRYPTION", "TUIST_MARKETING_VERSION", "TUIST_BUILD_NUMBER"]

enum Manifest: String {
  case project
  case package
}

struct Node {
  let raw: Any?

  subscript(_ key: String) -> Node {
    Node(raw: (raw as? [String: Any])?[key])
  }

  subscript(_ index: Int) -> Node {
    guard let array = raw as? [Any], array.indices.contains(index) else { return Node(raw: nil) }
    return Node(raw: array[index])
  }

  /// Tuist encodes `Plist.Value` and `SettingValue` as `{"<case>": {"_0": <payload>}}`.
  var value: Any? {
    guard let wrapper = raw as? [String: Any], wrapper.count == 1, let (kind, payload) = wrapper.first, let inner = (payload as? [String: Any])?["_0"] else { return raw }
    switch kind {
    case "array": return (inner as? [Any])?.map { Node(raw: $0).value ?? NSNull() }
    case "dictionary": return (inner as? [String: Any])?.mapValues { Node(raw: $0).value ?? NSNull() }
    default: return inner
    }
  }
}

final class Checker {
  private(set) var failures = 0
  private var cache: [String: Node?] = [:]
  private var diagnostics: [String: String] = [:]

  func load(_ manifest: Manifest, at path: String, _ environment: [String: String] = [:]) -> Node? {
    if let node = dump(manifest, at: path, environment) { return node }
    expect(false, "\(path) \(manifest) did not load with \(environment):\n\(diagnostics[key(manifest, path, environment)] ?? "")")
    return nil
  }

  func dump(_ manifest: Manifest, at path: String, _ environment: [String: String] = [:]) -> Node? {
    let key = key(manifest, path, environment)
    if let cached = cache[key] { return cached }
    var processEnvironment = ProcessInfo.processInfo.environment
    for option in optionKeys { processEnvironment[option] = nil }
    processEnvironment.merge(environment) { $1 }

    let process = Process()
    let output = Pipe()
    let errorLog = FileManager.default.temporaryDirectory.appending(path: "check-build-options-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: errorLog.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: errorLog) }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["tuist", "dump", manifest.rawValue, "--path", path]
    process.environment = processEnvironment
    process.standardOutput = output
    do {
      process.standardError = try FileHandle(forWritingTo: errorLog)
      try process.run()
    } catch {
      fatalError("cannot run tuist: \(error)")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let node = process.terminationStatus == 0 ? (try? JSONSerialization.jsonObject(with: data)).map { Node(raw: $0) } : nil
    cache[key] = node
    if node == nil {
      let errors = (try? String(contentsOf: errorLog, encoding: .utf8)) ?? ""
      diagnostics[key] = [String(decoding: data, as: UTF8.self), errors].joined(separator: "\n")
    }
    return node
  }

  private func key(_ manifest: Manifest, _ path: String, _ environment: [String: String]) -> String {
    "\(manifest) \(path) \(environment.sorted { $0.key < $1.key })"
  }

  func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    if condition { return }
    failures += 1
    print("FAIL \(message())")
  }

  func expectEqual(_ actual: Any?, _ expected: Any?, _ label: String) {
    let same =
      switch (actual, expected) {
      case (nil, nil): true
      case (let actual?, let expected?): (actual as AnyObject).isEqual(expected)
      default: false
      }
    expect(same, "\(label): expected \(expected.map { "\($0)" } ?? "absent"), found \(actual.map { "\($0)" } ?? "absent")")
  }
}

struct App {
  let name: String
  let displayName: String
  let category: String?
  let pushes: Bool
  let accentColor: Bool
}

let apps = [
  App(name: "NovelForge", displayName: "Novel Forge", category: "public.app-category.productivity", pushes: true, accentColor: false),
  App(name: "Memoir", displayName: "Memoir", category: "public.app-category.lifestyle", pushes: true, accentColor: false),
  App(name: "Catalog", displayName: "Catalog", category: nil, pushes: false, accentColor: true),
]

let storeBuild = ["TUIST_DEVELOPMENT_TEAM": "ABCDE12345", "TUIST_USES_NON_EXEMPT_ENCRYPTION": "false", "TUIST_MARKETING_VERSION": "1.2.3", "TUIST_BUILD_NUMBER": "42"]

let checker = Checker()

for app in apps {
  for (label, environment) in [("default", [String: String]()), ("store", storeBuild)] {
    guard let project = checker.load(.project, at: "Apps/\(app.name)", environment) else { continue }
    let target = project["targets"][0]
    let info = target["infoPlist"]["extendingDefault"]["with"]
    let base = target["settings"]["base"]
    let signed = label == "store"
    let context = "\(app.name) (\(label))"

    checker.expectEqual(info["CFBundleDisplayName"].value, app.displayName, "\(context) CFBundleDisplayName")
    checker.expectEqual(info["CFBundleName"].value, app.displayName, "\(context) CFBundleName")
    checker.expectEqual(info["LSApplicationCategoryType"].value, app.category, "\(context) LSApplicationCategoryType")
    checker.expectEqual(info["ITSAppUsesNonExemptEncryption"].value, signed ? false : nil, "\(context) ITSAppUsesNonExemptEncryption")
    checker.expectEqual(base["MARKETING_VERSION"].value, signed ? "1.2.3" : "1.0.0", "\(context) MARKETING_VERSION")
    checker.expectEqual(base["CURRENT_PROJECT_VERSION"].value, signed ? "42" : "1", "\(context) CURRENT_PROJECT_VERSION")
    checker.expectEqual(base["ASSETCATALOG_COMPILER_APPICON_NAME"].value, "AppIcon", "\(context) app ASSETCATALOG_COMPILER_APPICON_NAME")
    checker.expectEqual(project["targets"][1]["settings"]["base"]["ASSETCATALOG_COMPILER_APPICON_NAME"].value, nil, "\(context) tests ASSETCATALOG_COMPILER_APPICON_NAME")
    checker.expectEqual(base["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"].value, app.accentColor ? nil : "", "\(context) ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME")

    let pushes = signed && app.pushes
    let entitlements = target["entitlements"].value as? [String: Any]
    checker.expectEqual(entitlements?["$(SHADOW_APS_ENVIRONMENT_KEY)"], pushes ? "development" : nil, "\(context) aps-environment entitlement")
  }
}

if let novelForge = checker.load(.project, at: "Apps/NovelForge", ["TUIST_USES_NON_EXEMPT_ENCRYPTION": "true"]) {
  let encryption = novelForge["targets"][0]["infoPlist"]["extendingDefault"]["with"]["ITSAppUsesNonExemptEncryption"].value
  checker.expectEqual(encryption, true, "TUIST_USES_NON_EXEMPT_ENCRYPTION=true")
}

for (label, environment) in [("unset", [String: String]()), ("0", ["TUIST_UNRESTRICTED": "0"]), ("1", ["TUIST_UNRESTRICTED": "1"])] {
  guard let package = checker.load(.package, at: "Tuist", environment) else { continue }
  let targets = package["targetSettings"].raw as? [String: Any] ?? [:]
  checker.expect(!targets.isEmpty, "Tuist/Package.swift has no target settings")
  for name in targets.keys.sorted() {
    let conditions = package["targetSettings"][name]["base"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"].value
    let expected: [String]? = label == "1" && name == "NovelForgeCore" ? ["$(inherited)", "SHADOW_UNRESTRICTED"] : nil
    checker.expectEqual(conditions, expected, "\(name) (TUIST_UNRESTRICTED \(label)) SWIFT_ACTIVE_COMPILATION_CONDITIONS")
  }
}

let malformed: [(Manifest, String, [String: String])] = [
  (.package, "Tuist", ["TUIST_UNRESTRICTED": "yes"]),
  (.project, "Apps/NovelForge", ["TUIST_USES_NON_EXEMPT_ENCRYPTION": "YES"]),
  (.project, "Apps/NovelForge", ["TUIST_MARKETING_VERSION": "1.2.3.4"]),
  (.project, "Apps/NovelForge", ["TUIST_MARKETING_VERSION": "1..2"]),
  (.project, "Apps/NovelForge", ["TUIST_MARKETING_VERSION": "v1"]),
  (.project, "Apps/NovelForge", ["TUIST_BUILD_NUMBER": "1a"]),
]
for (manifest, path, environment) in malformed {
  checker.expect(checker.dump(manifest, at: path, environment) == nil, "\(path) loaded with \(environment) instead of stopping generation")
}

if checker.failures > 0 {
  print("\(checker.failures) build option check(s) failed")
  exit(1)
}
print("Build options: every check passed")
