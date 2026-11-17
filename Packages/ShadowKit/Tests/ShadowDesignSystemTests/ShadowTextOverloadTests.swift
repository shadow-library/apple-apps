import SwiftUI
import Testing

@testable import ShadowDesignSystem

@MainActor
@Suite("Text overloads")
struct ShadowTextOverloadTests {
  private let table = Text("Cancel", tableName: "Library")
  private let verbatim = Text(verbatim: "Cancel")

  @Test("should keep a catalog key bound to its table and tell it from runtime text")
  func tableIsKept() {
    #expect(table == Text("Cancel", tableName: "Library"))
    #expect(table != Text("Cancel", tableName: "Navigation"))
    #expect(table != verbatim)
  }

  @Test("should keep the given text and options in the sheet buttons")
  func sheetButtons() {
    let cancel = ShadowSheetCancel(table, systemImage: "chevron.left", isDisabled: true) {}
    let confirm = ShadowSheetConfirm(verbatim, systemImage: "plus", isDisabled: true) {}
    #expect(cancel.title == table)
    #expect(cancel.systemImage == "chevron.left")
    #expect(cancel.isDisabled)
    #expect(confirm.title == verbatim)
    #expect(confirm.systemImage == "plus")
    #expect(confirm.isDisabled)
    #expect(!confirm.submitShortcut)
  }

  @Test("should offer the submit shortcut only when asked")
  func submitShortcut() {
    #expect(ShadowSheetConfirm(table, submitShortcut: true) {}.submitShortcut)
    #expect(ShadowSheetConfirm("Save", submitShortcut: true) {}.submitShortcut)
    #expect(!ShadowSheetConfirm("Save") {}.submitShortcut)
  }

  @Test("should enable the cancel button by default and build the key overloads as before")
  func keyOverloads() {
    let cancel = ShadowSheetCancel("Cancel") {}
    let confirm = ShadowSheetConfirm("Save") {}
    #expect(!cancel.isDisabled)
    #expect(ShadowSheetCancel("Cancel", isDisabled: true) {}.isDisabled)
    #expect(cancel.title == Text("Cancel"))
    #expect(confirm.title == Text("Save"))
    #expect(!confirm.isDisabled)
  }

  @Test("should keep the label and caption of a statistic as given")
  func statistic() {
    let fromKey = ShadowStatistic("Readers", value: Text(verbatim: "3"))
    let fromText = ShadowStatistic(table, value: Text(verbatim: "3"))
    #expect(fromKey.label == Text("Readers"))
    #expect(fromText.label == table)
  }

  @Test("should keep the title and message of a content-unavailable state as given")
  func contentUnavailable() {
    let fromKey = ShadowContentUnavailable("Nothing here", message: "Try later")
    let fromText = ShadowContentUnavailable(table, kind: .error, message: verbatim)
    #expect(fromKey.title == Text("Nothing here"))
    #expect(fromKey.message == Text("Try later"))
    #expect(fromText.title == table)
    #expect(fromText.message == verbatim)
  }
}
