import Foundation

/// The app's marketing version and build number as its bundle states them; the build is left out when the bundle has none or repeats the version.
public nonisolated struct AppVersion: Hashable, Sendable {
  public let version: String
  public let build: String?

  public init(version: String, build: String?) {
    self.version = version
    self.build = build == version ? nil : build
  }

  public init(info: [String: Any]?) {
    let version = info?["CFBundleShortVersionString"] as? String
    let build = info?["CFBundleVersion"] as? String
    self.init(version: version ?? build ?? "?", build: version == nil ? nil : build)
  }

  public init(bundle: Bundle = .main) {
    self.init(info: bundle.infoDictionary)
  }

  /// "1.2 (45)", or "1.2" without a build: numbers, the same in every language.
  public var text: String {
    guard let build else { return version }
    return "\(version) (\(build))"
  }

  public var label: LocalizedStringResource {
    LocalizedStringResource("Version \(text)", table: "About", bundle: .shell)
  }
}

extension LocalizedStringResource.BundleDescription {
  nonisolated static var shell: Self { .atURL(Bundle.module.bundleURL) }
}
