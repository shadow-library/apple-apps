import Testing

@testable import NovelForgeCore

struct ProseMarkdownSpecTests {
  @Test func shouldKeepPlainProseAndSafeLinksUntouched() {
    let text = "She read [the map](https://example.com/map \"Map\") and ![a ship](images/ship.png).\n\n*Quiet*, she said."
    #expect(ProseMarkdown.sanitize(text) == text)
  }

  @Test func shouldNormalizeEveryLineEndingToANewline() {
    #expect(ProseMarkdown.sanitize("a\r\nb\rc") == "a\nb\nc")
  }

  @Test func shouldReturnEmptyTextAsIs() {
    #expect(ProseMarkdown.sanitize("") == "")
  }

  @Test func shouldReplaceADangerousLinkWithItsText() {
    #expect(ProseMarkdown.sanitize("[click](javascript:alert(1)) now") == "click now")
    #expect(ProseMarkdown.sanitize("![alt](data:text/html;base64,AAAA)") == "alt")
    #expect(ProseMarkdown.sanitize("[v](vbscript:run)") == "v")
  }

  @Test func shouldJudgeTheSchemeAfterDecodingEntitiesAndDroppingControlCharacters() {
    #expect(ProseMarkdown.isDangerousURL("javascript&colon;alert(1)"))
    #expect(ProseMarkdown.isDangerousURL("java&#115;cript:alert(1)"))
    #expect(ProseMarkdown.isDangerousURL("java&#x73;cript:alert(1)"))
    #expect(ProseMarkdown.isDangerousURL("  JaVa\tScRiPt:alert(1)"))
    #expect(ProseMarkdown.isDangerousURL("java&Tab;script:alert(1)"))
  }

  @Test func shouldAllowOrdinaryDestinations() {
    #expect(!ProseMarkdown.isDangerousURL("https://example.com/?q=javascript:"))
    #expect(!ProseMarkdown.isDangerousURL("mailto:a@b.c"))
    #expect(!ProseMarkdown.isDangerousURL("/chapters/2#data:x"))
    #expect(!ProseMarkdown.isDangerousURL(""))
  }

  @Test func shouldLeaveAnUndecodableEntityAsItIs() {
    #expect(ProseMarkdown.decodeEntities("&#xD800;&#99999999;&unknown;") == "&#xD800;&#99999999;&unknown;")
    #expect(ProseMarkdown.decodeEntities("&lt;&amp;&#65;") == "<&A")
  }

  @Test func shouldSanitizeLinksNestedInLinkText() {
    #expect(ProseMarkdown.sanitize("[![x](javascript:a)](javascript:b)") == "x")
    #expect(ProseMarkdown.sanitize("[![x](img.png)](javascript:b)") == "![x](img.png)")
  }

  @Test func shouldHandleAngleBracketDestinationsAndTitles() {
    #expect(ProseMarkdown.sanitize("[a](<javascript:x> \"t\")") == "a")
    #expect(ProseMarkdown.sanitize("[a](javascript:x 'title')") == "a")
    #expect(ProseMarkdown.sanitize("[a](https://e.com/(x))") == "[a](https://e.com/(x))")
  }

  @Test func shouldDropADangerousReferenceDefinition() {
    #expect(ProseMarkdown.sanitize("[go][1]\n\n[1]: javascript:alert(1)\n[2]: https://example.com") == "[go][1]\n\n[2]: https://example.com")
  }

  @Test func shouldShowRawHTMLAsText() {
    #expect(ProseMarkdown.sanitize("a <script>x</script> b") == "a \\<script>x\\</script> b")
    #expect(ProseMarkdown.sanitize("<img src=x onerror=y>") == "\\<img src=x onerror=y>")
    #expect(ProseMarkdown.sanitize("<!-- c -->") == "\\<!-- c -->")
  }

  @Test func shouldKeepASafeAutolinkAndShowADangerousOneAsText() {
    #expect(ProseMarkdown.sanitize("<https://example.com>") == "<https://example.com>")
    #expect(ProseMarkdown.sanitize("<javascript:alert(1)>") == "javascript:alert(1)")
  }

  @Test func shouldKeepALiteralLessThanBeforeANumberOrSpace() {
    #expect(ProseMarkdown.sanitize("2 < 3 and 1<2") == "2 < 3 and 1<2")
  }

  @Test func shouldNotTreatAnEscapedBracketAsALink() {
    #expect(ProseMarkdown.sanitize(#"\[a](javascript:x)"#) == #"\[a](javascript:x)"#)
  }

  @Test func shouldLeaveAnUnclosedLinkAlone() {
    #expect(ProseMarkdown.sanitize("[a](javascript:x") == "[a](javascript:x")
    #expect(ProseMarkdown.sanitize("[a](") == "[a](")
  }
}

struct ProseMarkdownGapTests {
  @Test func shouldUnescapePunctuationBeforeJudgingTheScheme() {
    #expect(ProseMarkdown.sanitize(#"[a](javascript\:alert(1))"#) == "a")
    #expect(ProseMarkdown.sanitize(#"[a](<java\script:x>)"#) == #"[a](<java\script:x>)"#)
  }

  @Test func shouldNeutralizeTheLabelOfASafeLink() {
    #expect(ProseMarkdown.sanitize("[![x](javascript:a)](https://example.com)") == "[x](https://example.com)")
    #expect(ProseMarkdown.sanitize("[<b>hi](https://example.com)") == "[\\<b>hi](https://example.com)")
  }

  @Test func shouldDropEveryShapeOfDangerousDefinition() {
    #expect(ProseMarkdown.sanitize("a\n[x]:\n  javascript:alert(1)\nb") == "a\nb")
    #expect(ProseMarkdown.sanitize("a\n[x\\]y]: javascript:alert(1)\nb") == "a\nb")
    #expect(ProseMarkdown.sanitize("a\n[x]: javascript:alert(1) \"title\"\nb") == "a\nb")
    #expect(ProseMarkdown.sanitize("a\n> [x]: javascript:alert(1)\nb") == "a\nb")
    #expect(ProseMarkdown.sanitize("a\n- [x]: <vbscript:run>\nb") == "a\nb")
    #expect(ProseMarkdown.sanitize("a\n1. [x]: data:text/html,x\nb") == "a\nb")
    #expect(ProseMarkdown.sanitize("a\n[x]: https://example.com\nb") == "a\n[x]: https://example.com\nb")
  }

  @Test func shouldNotLetACodeSpanOrFenceCrossABlankLine() {
    #expect(ProseMarkdown.sanitize("`\n\n[x](javascript:alert(1))\n\n`") == "`\n\nx\n\n`")
    #expect(ProseMarkdown.sanitize("```\n\n[x](javascript:alert(1))\n\n```") == "```\n\nx\n\n```")
    #expect(ProseMarkdown.sanitize("```\n\n[1]: javascript:alert(1)\n\n```") == "```\n\n\n```")
    #expect(ProseMarkdown.sanitize("`a\nb [x](javascript:y)`") == "`a\nb [x](javascript:y)`")
  }

  @Test func shouldLeaveCodeUntouched() {
    #expect(ProseMarkdown.sanitize("`[a](javascript:x)` and `<script>`") == "`[a](javascript:x)` and `<script>`")
    #expect(ProseMarkdown.sanitize("``a ` [b](javascript:x)``") == "``a ` [b](javascript:x)``")
    #expect(ProseMarkdown.sanitize("```\n[x]: javascript:y\n```") == "```\n[x]: javascript:y\n```")
    #expect(ProseMarkdown.sanitize("`unclosed [a](javascript:x)") == "`unclosed a")
  }
}

private struct MarkdownURLFixture: Decodable {
  struct Case: Decodable {
    let url: String
    let dangerous: Bool

    init(from decoder: any Decoder) throws {
      var container = try decoder.unkeyedContainer()
      url = try container.decode(String.self)
      dangerous = try container.decode(Bool.self)
    }
  }

  let cases: [Case]
}

struct ProseMarkdownParityTests {
  @Test func shouldCollapseExactlyTheDestinationsTheReferenceCollapses() throws {
    let cases = try ReferenceFixture.decode(MarkdownURLFixture.self, from: "prose/markdown-urls.json").cases
    #expect(cases.count >= 900)
    #expect(cases.contains { $0.dangerous } && cases.contains { !$0.dangerous })
    let mismatches = cases.filter { reference in
      (ProseMarkdown.sanitize("[t](<\(reference.url)>)") == "t") != reference.dangerous
    }
    #expect(mismatches.map(\.url) == [])
  }
}
