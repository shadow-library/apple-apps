import Testing

@testable import ShadowDesignSystem

@Suite("Token entry")
struct ShadowTokenEntryTests {
  private let rules = ShadowTokenRules<String>()

  @Test("should commit the trimmed text on Return")
  func commit() {
    var entry = ShadowTokenEntry<String>(text: "  user.created ")
    let outcome = entry.commit(rules: rules)
    #expect(outcome == .added)
    #expect(entry.tokens == ["user.created"])
    #expect(entry.text.isEmpty)
  }

  @Test("should ignore an empty commit")
  func emptyCommit() {
    var entry = ShadowTokenEntry<String>(text: "   ")
    let outcome = entry.commit(rules: rules)
    #expect(outcome == .empty)
    #expect(entry.tokens.isEmpty)
  }

  @Test("should commit on a comma and keep the remainder as text")
  func comma() {
    var entry = ShadowTokenEntry<String>()
    let outcomes = entry.type("user.created,", rules: rules)
    #expect(outcomes == [.added])
    #expect(entry.tokens == ["user.created"])
    #expect(entry.text.isEmpty)
    entry.type("session.revoked, role.gr", rules: rules)
    #expect(entry.tokens == ["user.created", "session.revoked"])
    #expect(entry.text == " role.gr")
  }

  @Test("should split a pasted list into tokens and skip empty pieces")
  func pastedList() {
    var entry = ShadowTokenEntry<String>()
    entry.type("fantasy,,mystery\nromance", rules: rules)
    #expect(entry.tokens == ["fantasy", "mystery"])
    #expect(entry.text == "romance")
  }

  @Test("should reject duplicates case-insensitively and select the existing token")
  func duplicates() {
    var entry = ShadowTokenEntry(tokens: ["Fantasy", "Mystery"], text: "fantasy")
    let outcome = entry.commit(rules: rules)
    #expect(outcome == .duplicate(index: 0))
    #expect(entry.tokens == ["Fantasy", "Mystery"])
    #expect(entry.selection == 0)
    #expect(entry.text.isEmpty)
  }

  @Test("should allow case variants when the comparison is case-sensitive")
  func caseSensitive() {
    var entry = ShadowTokenEntry(tokens: ["Fantasy"], text: "fantasy")
    let outcome = entry.commit(rules: ShadowTokenRules(comparison: .caseSensitive))
    #expect(outcome == .added)
    #expect(entry.tokens == ["Fantasy", "fantasy"])
  }

  @Test("should refuse tokens past the maximum and keep the typed text")
  func limit() {
    var entry = ShadowTokenEntry(tokens: ["a", "b"], text: "c")
    let outcome = entry.commit(rules: ShadowTokenRules(maximumCount: 2))
    #expect(outcome == .limitReached)
    #expect(entry.tokens == ["a", "b"])
    #expect(entry.text == "c")
  }

  @Test("should keep text the parser rejects")
  func invalid() {
    let rules = ShadowTokenRules<Int>(label: { String($0) }, parse: { Int($0) })
    var entry = ShadowTokenEntry<Int>(text: "four")
    let rejected = entry.commit(rules: rules)
    #expect(rejected == .invalid)
    #expect(entry.text == "four")
    entry.text = "4"
    let accepted = entry.commit(rules: rules)
    #expect(accepted == .added)
    #expect(entry.tokens == [4])
  }

  @Test("should select the last token on the first Backspace and remove it on the second")
  func backspace() {
    var entry = ShadowTokenEntry(tokens: ["user.created", "session.revoked"])
    let first = entry.deleteBackward()
    #expect(first == .selected(index: 1))
    #expect(entry.tokens.count == 2)
    let second = entry.deleteBackward()
    #expect(second == .removed(index: 1))
    #expect(entry.tokens == ["user.created"])
    #expect(entry.selection == nil)
  }

  @Test("should not touch tokens on Backspace while text remains")
  func backspaceWithText() {
    var entry = ShadowTokenEntry(tokens: ["user.created"], text: "ro")
    let deletion = entry.deleteBackward()
    #expect(deletion == .none)
    #expect(entry.tokens == ["user.created"])
  }

  @Test("should clear the selection when typing")
  func typingDeselects() {
    var entry = ShadowTokenEntry(tokens: ["user.created"], selection: 0)
    entry.type("r", rules: rules)
    #expect(entry.selection == nil)
  }

  @Test("should shift the selection when an earlier token is removed")
  func removeShiftsSelection() {
    var entry = ShadowTokenEntry(tokens: ["a", "b", "c"], selection: 2)
    entry.remove(at: 0)
    #expect(entry.selection == 1)
    entry.remove(at: 1)
    #expect(entry.selection == nil)
  }

  @Test("should drop an out-of-range selection")
  func invalidSelection() {
    #expect(ShadowTokenEntry(tokens: ["a"], selection: 3).selection == nil)
  }
}

@Suite("Token suggestions")
struct ShadowTokenSuggestionTests {
  private let candidates = ["role.granted", "role.revoked", "user.role.changed", "session.revoked", "Rôle.audit"]

  @Test("should rank prefix matches first and exclude existing tokens")
  func ranking() {
    let rules = ShadowTokenRules<String>()
    #expect(rules.suggestions(from: candidates, matching: "role", excluding: ["role.revoked"]) == ["role.granted", "Rôle.audit", "user.role.changed"])
  }

  @Test("should suggest nothing for empty text or at the limit")
  func nothing() {
    #expect(ShadowTokenRules<String>().suggestions(from: candidates, matching: "  ", excluding: []).isEmpty)
    #expect(ShadowTokenRules<String>(maximumCount: 1).suggestions(from: candidates, matching: "role", excluding: ["x"]).isEmpty)
  }

  @Test("should cap the number of suggestions")
  func cap() {
    #expect(ShadowTokenRules<String>(suggestionLimit: 1).suggestions(from: candidates, matching: "o", excluding: []).count == 1)
  }
}

@Suite("Token text input")
struct ShadowTokenTextInputTests {
  private let sentinel = ShadowTokenTextInput.sentinel

  @Test("should hold the sentinel only while the text is empty")
  func rawForText() {
    #expect(ShadowTokenTextInput.raw(for: "") == sentinel)
    #expect(ShadowTokenTextInput.raw(for: "role") == "role")
  }

  @Test("should report Backspace when the sentinel is deleted from an empty field and restore it")
  func backspaceOnEmpty() {
    #expect(ShadowTokenTextInput.interpret("", currentText: "") == .init(change: .backspaceOnEmpty, raw: sentinel))
  }

  @Test("should strip the sentinel from typed text without touching the raw text")
  func typing() {
    #expect(ShadowTokenTextInput.interpret(sentinel + "r", currentText: "") == .init(change: .text("r"), raw: nil))
    #expect(ShadowTokenTextInput.interpret("r" + sentinel, currentText: "") == .init(change: .text("r"), raw: nil))
    #expect(ShadowTokenTextInput.interpret("ro\u{200B}le", currentText: "ro") == .init(change: .text("role"), raw: nil))
  }

  @Test("should leave text and caret alone when Backspace at the start removes the sentinel")
  func backspaceAtStart() {
    #expect(ShadowTokenTextInput.interpret("role", currentText: "role") == .init(change: .none, raw: nil))
  }

  @Test("should restore the sentinel when the last character is deleted")
  func deleteLastCharacter() {
    #expect(ShadowTokenTextInput.interpret("", currentText: "r") == .init(change: .text(""), raw: sentinel))
    #expect(ShadowTokenTextInput.interpret(sentinel, currentText: "r") == .init(change: .text(""), raw: nil))
  }

  @Test("should reset the raw text only when a commit changed the text")
  func normalizedAfterCommit() {
    #expect(ShadowTokenTextInput.normalized("role,", for: "") == sentinel)
    #expect(ShadowTokenTextInput.normalized(sentinel, for: "") == nil)
    #expect(ShadowTokenTextInput.normalized(sentinel + "role", for: "role") == nil)
    #expect(ShadowTokenTextInput.normalized("a, role", for: " role") == " role")
  }
}
