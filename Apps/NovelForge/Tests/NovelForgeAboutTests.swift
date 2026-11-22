import Foundation
import ShadowAppShell
import Testing

@testable import NovelForge

@MainActor
@Suite("Novel Forge About", TestTimeLimit.standard)
struct NovelForgeAboutTests {
  @Test("should say what leaves the device in Novel Forge's words")
  func shouldSayWhatLeavesTheDeviceInNovelForgesWords() {
    let lines = AboutDisclosure.novelForge

    #expect(lines.map(\.id) == ["model-provider", "sync", "keychain", "nothing-else"])
    for line in lines { #expect(line.text.isInCatalog, "\(line.id)") }
    #expect(String(localized: lines[0].text).contains("Novel Forge sends what the request needs"))
    #expect(String(localized: lines[1].text).contains("your library is encrypted on this device"))
  }

  @Test("should show no privacy, support or contact row until Novel Forge has them")
  func shouldShowNoPrivacySupportOrContactRowUntilNovelForgeHasThem() {
    #expect(AboutLink.links(for: .novelForge, version: AppVersion(version: "1.0", build: "1")).isEmpty)
  }
}

extension LocalizedStringResource {
  fileprivate var isInCatalog: Bool { bundle.resolved?.localizedString(forKey: key, value: "MISSING", table: table) ?? "MISSING" != "MISSING" }
}

extension LocalizedStringResource.BundleDescription {
  fileprivate var resolved: Bundle? {
    switch self {
    case .main: .main
    case .forClass(let type): Bundle(for: type)
    case .atURL(let url): Bundle(url: url)
    @unknown default: nil
    }
  }
}
