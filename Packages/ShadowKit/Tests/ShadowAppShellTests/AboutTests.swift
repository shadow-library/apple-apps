import Foundation
import Testing

@testable import ShadowAppShell

@Suite("About", TestTimeLimit.quick)
struct AboutTests {
  @Test("should keep an identity made without About values free of rows")
  func shouldKeepAnIdentityMadeWithoutAboutValuesFreeOfRows() {
    let app = AppIdentity.fixture

    #expect(app.privacyPolicyURL == nil)
    #expect(app.supportURL == nil)
    #expect(app.contactAddress == nil)
    #expect(AboutLink.links(for: app, version: AppVersion(version: "1.0", build: "1")).isEmpty)
  }

  @Test("should show a row for each About value the identity sets, in order")
  func shouldShowARowForEachAboutValueTheIdentitySetsInOrder() throws {
    let privacy = try #require(URL(string: "https://example.com/privacy"))
    let support = try #require(URL(string: "https://example.com/support"))
    let app = AppIdentity.about(privacy: privacy, support: support, contact: "help@example.com")

    let links = AboutLink.links(for: app, version: AppVersion(version: "1.0", build: "42"))

    #expect(links.map(\.id) == ["privacy-policy", "support", "contact"])
    #expect(links.first?.url == privacy)
    #expect(links.dropFirst().first?.url == support)
    #expect(links.last?.url.scheme == "mailto")
  }

  @Test("should show only the rows whose values are set", arguments: [(true, false, false), (false, true, false), (false, false, true), (true, false, true)])
  func shouldShowOnlyTheRowsWhoseValuesAreSet(privacy: Bool, support: Bool, contact: Bool) {
    let app = AppIdentity.about(
      privacy: privacy ? URL(string: "https://example.com/privacy") : nil, support: support ? URL(string: "https://example.com/help") : nil,
      contact: contact ? "help@example.com" : nil)

    let ids = AboutLink.links(for: app, version: AppVersion(version: "1.0", build: nil)).map(\.id)

    #expect(ids == [privacy ? "privacy-policy" : nil, support ? "support" : nil, contact ? "contact" : nil].compactMap(\.self))
  }

  @Test("should leave out a page that is not https and an address that is not one mailbox")
  func shouldLeaveOutAPageThatIsNotHTTPSAndAnAddressThatIsNotOneMailbox() {
    let pages = ["http://example.com/privacy", "file:///etc/passwd", "mailto:help@example.com", "https:///privacy"].compactMap { URL(string: $0) }
    let addresses = ["", "help", "help@", "@example.com", "help@example", "a@b@example.com", "help @example.com", "help@example.com?cc=x@example.com", "help@.com"]

    for page in pages {
      #expect(AboutLink.links(for: .about(privacy: page, support: page, contact: nil), version: AppVersion(version: "1", build: nil)).isEmpty)
    }
    for address in addresses {
      #expect(AboutLink.links(for: .about(privacy: nil, support: nil, contact: address), version: AppVersion(version: "1", build: nil)).isEmpty, "\(address)")
    }
  }

  @Test("should build a mailto link naming the app and its version in the subject")
  func shouldBuildAMailtoLinkNamingTheAppAndItsVersionInTheSubject() throws {
    let url = try #require(AboutLink.mailto("help+memoir@example.com", subject: "Shell Test 1.0 (42)"))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

    #expect(url.absoluteString == "mailto:help+memoir@example.com?subject=Shell%20Test%201.0%20(42)")
    #expect(components.path == "help+memoir@example.com")
    #expect(components.queryItems == [URLQueryItem(name: "subject", value: "Shell Test 1.0 (42)")])
  }

  @Test("should put the app's name and version in the contact link's subject")
  func shouldPutTheAppsNameAndVersionInTheContactLinksSubject() throws {
    let links = AboutLink.links(for: .about(privacy: nil, support: nil, contact: "help@example.com"), version: AppVersion(version: "2.1", build: "7"))
    let url = try #require(links.first?.url)

    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Shell Test 2.1 (7)")
  }

  @Test("should read the version and build from the bundle's info")
  func shouldReadTheVersionAndBuildFromTheBundlesInfo() {
    #expect(AppVersion(info: ["CFBundleShortVersionString": "1.4", "CFBundleVersion": "88"]).text == "1.4 (88)")
    #expect(AppVersion(info: ["CFBundleShortVersionString": "1.4", "CFBundleVersion": "1.4"]).text == "1.4")
    #expect(AppVersion(info: ["CFBundleShortVersionString": "1.4"]).text == "1.4")
    #expect(AppVersion(info: ["CFBundleVersion": "88"]).text == "88")
    #expect(AppVersion(info: nil).text == "?")
  }

  @Test("should word the version for the screen from the About catalog")
  func shouldWordTheVersionForTheScreenFromTheAboutCatalog() {
    let label = AppVersion(version: "1.4", build: "88").label

    #expect(label.isInCatalog)
    #expect(String(localized: label) == "Version 1.4 (88)")
  }

  @Test("should word the shell's disclosures from the About catalog with the app's names")
  func shouldWordTheShellsDisclosuresFromTheAboutCatalogWithTheAppsNames() {
    let app = AppIdentity.fixture
    let disclosures = [AboutDisclosure.modelProvider(app: app), .sync(app: app), .keychain(app: app), .nothingElse(app: app)]

    for disclosure in disclosures { #expect(disclosure.text.isInCatalog, "\(disclosure.id)") }
    #expect(String(localized: disclosures[0].text).contains("Shell Test sends what the request needs from your own devices"))
    #expect(String(localized: disclosures[1].text).hasPrefix("When you turn on sync, your library is encrypted"))
    #expect(String(localized: disclosures[2].text).contains("Shell Test keeps your AI provider keys, your library's sync keys"))
    #expect(String(localized: disclosures[3].text).contains("Shell Test has no account"))
  }

  @Test("should find every word the About screen shows in the About catalog")
  func shouldFindEveryWordTheAboutScreenShowsInTheAboutCatalog() {
    let keys = [
      "About %@", "What leaves this device", "Privacy and support", "Privacy Policy", "Support", "Contact", "Acknowledgements",
      "The notices of the third-party work %@ includes.",
    ]

    for key in keys { #expect(Bundle.module.localizedString(forKey: key, value: "MISSING", table: "About") != "MISSING", "\(key)") }
  }

  @Test("should tell a key missing from the catalog")
  func shouldTellAKeyMissingFromTheCatalog() {
    #expect(!LocalizedStringResource("Not in the catalog", table: "About", bundle: .shell).isInCatalog)
  }

  @Test("should load the bundled acknowledgements")
  func shouldLoadTheBundledAcknowledgements() throws {
    let acknowledgements = try #require(Acknowledgements.bundled)

    #expect(acknowledgements.blocks.first == .heading(level: 1, text: "Third-party notices"))
    #expect(acknowledgements.blocks.contains(.heading(level: 2, text: "BIP-39 English word list")))
    #expect(acknowledgements.blocks.contains { if case .preformatted(let text) = $0 { text.hasPrefix("MIT License") } else { false } })
  }

  @Test("should bundle the repository's notices unchanged")
  func shouldBundleTheRepositorysNoticesUnchanged() throws {
    let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../THIRD_PARTY_NOTICES.md").standardizedFileURL
    let bundled = try #require(Bundle.module.url(forResource: "ThirdPartyNotices", withExtension: "md"))

    #expect(try String(contentsOf: bundled, encoding: .utf8) == String(contentsOf: root, encoding: .utf8))
  }

  @Test("should leave the acknowledgements out when the bundle has no notices")
  func shouldLeaveTheAcknowledgementsOutWhenTheBundleHasNoNotices() throws {
    let empty = FileManager.default.temporaryDirectory.appending(path: "about-\(UUID().uuidString).bundle", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }

    #expect(Acknowledgements.load(from: try #require(Bundle(url: empty))) == nil)
  }

  @Test("should read headings, items, paragraphs and fenced blocks")
  func shouldReadHeadingsItemsParagraphsAndFencedBlocks() {
    let markdown = "# Notices\n\n## One\n\n- Used in: `A.swift`.\n- Licence: MIT.\n\nFirst line\nsecond line.\n\n```\nMIT License\n\n  indented\n```\n#not a heading\n"

    #expect(
      Acknowledgements(markdown: markdown).blocks == [
        .heading(level: 1, text: "Notices"), .heading(level: 2, text: "One"), .item("Used in: `A.swift`."), .item("Licence: MIT."),
        .paragraph("First line second line."), .preformatted("MIT License\n\n  indented"), .paragraph("#not a heading"),
      ])
  }

  @Test("should keep an unclosed fence as preformatted text")
  func shouldKeepAnUnclosedFenceAsPreformattedText() {
    #expect(Acknowledgements(markdown: "Intro\n```\nlicence text").blocks == [.paragraph("Intro"), .preformatted("licence text")])
  }
}

extension AppIdentity {
  fileprivate static func about(privacy: URL?, support: URL?, contact: String?) -> AppIdentity {
    AppIdentity(
      id: fixture.id, displayName: fixture.displayName, vaultNoun: fixture.vaultNoun, vaultTitle: fixture.vaultTitle, exampleBucketName: fixture.exampleBucketName,
      privacyPolicyURL: privacy, supportURL: support, contactAddress: contact)
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
