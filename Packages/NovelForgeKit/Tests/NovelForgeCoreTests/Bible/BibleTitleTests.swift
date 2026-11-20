import ShadowCore
import ShadowText
import Testing

@testable import NovelForgeCore

@Suite("Bible page titles")
struct BibleTitleTests {
  struct Case: Sendable {
    let slug: String
    let frontmatter: [String: JSONValue]?
    let body: String?
    let title: String
  }

  // Expected values come from running deriveBibleDocTitle of the reference with bun
  static let cases: [Case] = [
    Case(slug: "the-hidden_war", frontmatter: nil, body: nil, title: "The hidden war"),
    Case(slug: "x", frontmatter: ["title": "  Given  "], body: "# H", title: "Given"),
    Case(slug: "x", frontmatter: ["title": "  "], body: "intro\n#   Heading \nmore", title: "Heading"),
    Case(slug: "x", frontmatter: nil, body: "#\n\nSplit title", title: "Split title"),
    Case(slug: "x", frontmatter: nil, body: "#  ", title: ""),
    Case(slug: "x", frontmatter: nil, body: "#", title: "X"),
    Case(slug: "x", frontmatter: nil, body: "a\r# Crlf\r\nz", title: "Crlf"),
    Case(slug: "x", frontmatter: ["title": 5], body: "## no\n#\tTab", title: "Tab"),
    Case(slug: "--", frontmatter: nil, body: "", title: ""),
    Case(slug: "\u{e9}lan-vital", frontmatter: nil, body: nil, title: "\u{c9}lan vital"),
    Case(slug: "\u{df}eta", frontmatter: nil, body: nil, title: "SSeta"),
    Case(slug: "x", frontmatter: nil, body: "#a", title: "X"),
    Case(slug: "x", frontmatter: nil, body: "text\u{2028}# Sep\u{2029}", title: "Sep"),
    Case(slug: "\u{1F600}-x", frontmatter: nil, body: nil, title: "\u{1F600} x"),
    Case(slug: "x", frontmatter: nil, body: "#   ", title: ""),
    Case(slug: "my-slug", frontmatter: nil, body: "# ", title: "My slug"),
    Case(slug: "my-slug", frontmatter: nil, body: "Intro\n# ", title: "My slug"),
    Case(slug: "my-slug", frontmatter: nil, body: "#\u{3000}", title: "My slug"),
    Case(slug: "my-slug", frontmatter: nil, body: "# \n", title: "My slug"),
    Case(slug: "my-slug", frontmatter: nil, body: "#\u{a0}Title\u{a0}", title: "Title"),
    Case(slug: "my-slug", frontmatter: nil, body: "text\u{2029}# Sep", title: "Sep"),
    Case(slug: "\u{1D49C}bc", frontmatter: nil, body: "", title: "\u{1D49C}bc"),
  ]

  @Test(arguments: cases)
  func shouldDeriveTheTitleAsTheReferenceDoes(_ testCase: Case) {
    #expect(BibleTitle.derive(slug: testCase.slug, frontmatter: testCase.frontmatter, body: testCase.body) == testCase.title)
  }

  @Test
  func shouldKeepAnAuthoredTitleExactlyAndFoldADerivedOneIntoOtherFrontmatter() {
    let authored: [String: JSONValue] = ["title": " Kept ", "tags": ["a"]]
    #expect(BibleTitle.ensure(slug: "s", frontmatter: authored, body: "# Other") == authored)
    #expect(BibleTitle.ensure(slug: "s", frontmatter: ["tags": ["a"]], body: "# Other") == ["tags": ["a"], "title": "Other"])
    #expect(BibleTitle.ensure(slug: "the-end", frontmatter: nil, body: nil) == ["title": "The end"])
  }
}
