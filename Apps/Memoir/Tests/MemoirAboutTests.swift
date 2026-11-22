import Foundation
import ShadowAppShell
import Testing

@testable import Memoir

@MainActor
@Suite("Memoir About", TestTimeLimit.quick)
struct MemoirAboutTests {
  @Test("should say what leaves the device, with Memoir's own lines between the shell's")
  func shouldSayWhatLeavesTheDeviceWithMemoirsOwnLinesBetweenTheShells() {
    let lines = AboutDisclosure.memoir

    #expect(lines.map(\.id) == ["model-provider", "receipts", "sync", "keychain", "health", "nothing-else"])
    for line in lines { #expect(line.text.isInCatalog, "\(line.id)") }
    #expect(String(localized: lines[1].text).hasPrefix("The text of a receipt goes to your AI provider only after you allow it"))
    #expect(String(localized: lines[2].text).contains("your vault is encrypted on this device"))
    #expect(String(localized: lines[4].text).hasPrefix("Health data never syncs through iCloud"))
  }

  @Test("should find the About row's words in the Settings catalog")
  func shouldFindTheAboutRowsWordsInTheSettingsCatalog() {
    for key in ["About Memoir", "What leaves this device, and the notices of the third-party work Memoir includes."] {
      #expect(Bundle.main.localizedString(forKey: key, value: "MISSING", table: "Settings") != "MISSING", "\(key)")
    }
  }

  @Test("should show no privacy, support or contact row until Memoir has them")
  func shouldShowNoPrivacySupportOrContactRowUntilMemoirHasThem() {
    #expect(AboutLink.links(for: .memoir, version: AppVersion(version: "1.0", build: "1")).isEmpty)
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
