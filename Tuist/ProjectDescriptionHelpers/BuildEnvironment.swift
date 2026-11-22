import ProjectDescription

/// A malformed value stops generation, but Tuist drops a manifest's crash message and reports only that the manifest failed to load.
enum BuildEnvironment {
  static let unrestricted = flag(Environment.unrestricted, named: "TUIST_UNRESTRICTED")
  static let usesNonExemptEncryption = optionalBoolean(Environment.usesNonExemptEncryption, named: "TUIST_USES_NON_EXEMPT_ENCRYPTION")
  static let marketingVersion = version(Environment.marketingVersion, named: "TUIST_MARKETING_VERSION", default: "1.0.0")
  static let buildNumber = version(Environment.buildNumber, named: "TUIST_BUILD_NUMBER", default: "1")

  private static func flag(_ value: Environment.Value?, named name: String) -> Bool {
    switch value.getString(default: "") {
    case "", "0": return false
    case "1": return true
    case let other: preconditionFailure("\(name) must be 1 or 0, not \"\(other)\"")
    }
  }

  private static func optionalBoolean(_ value: Environment.Value?, named name: String) -> Bool? {
    switch value.getString(default: "") {
    case "": return nil
    case "true": return true
    case "false": return false
    case let other: preconditionFailure("\(name) must be true or false, not \"\(other)\"")
    }
  }

  /// `CFBundleShortVersionString` and `CFBundleVersion` both take one to three period-separated integers.
  private static func version(_ value: Environment.Value?, named name: String, default fallback: String) -> String {
    let version = value.getString(default: "")
    if version.isEmpty { return fallback }
    let components = version.split(separator: ".", omittingEmptySubsequences: false)
    let valid = (1...3).contains(components.count) && components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    precondition(valid, "\(name) must be one to three period-separated integers, not \"\(version)\"")
    return version
  }
}
