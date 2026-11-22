import Foundation

/// The journal's markdown-lite toolbar (`applyMarkdownTool`, `quick-logs.rules.ts`): bold and italic wrap the selection, quote, list and heading prefix
/// its line. Offsets count UTF-16 code units, as the reference's string indices do.
nonisolated enum MarkdownTool: String, CaseIterable, Hashable, Sendable {
  case bold
  case italic
  case quote
  case list
  case heading

  struct Edit: Equatable {
    let text: String
    let selectionStart: Int
    let selectionEnd: Int
  }

  var glyph: String {
    switch self {
    case .bold: "B"
    case .italic: "I"
    case .quote: "“"
    case .list: "•"
    case .heading: "H"
    }
  }

  var label: String {
    switch self {
    case .bold: String(localized: "Bold", table: "Log")
    case .italic: String(localized: "Italic", table: "Log")
    case .quote: String(localized: "Quote", table: "Log")
    case .list: String(localized: "List", table: "Log")
    case .heading: String(localized: "Heading", table: "Log")
    }
  }

  private var wrapper: String? {
    switch self {
    case .bold: "**"
    case .italic: "_"
    case .quote, .list, .heading: nil
    }
  }

  private var prefix: String {
    switch self {
    case .quote: "> "
    case .list: "- "
    case .heading: "## "
    case .bold, .italic: ""
    }
  }

  func apply(to text: String, selectionStart: Int, selectionEnd: Int) -> Edit {
    let units = Array(text.utf16)
    let start = min(max(0, selectionStart), units.count)
    let end = min(max(start, selectionEnd), units.count)
    if let wrapper {
      let inserted = Array(wrapper.utf16)
      let edited = Array(units[..<start]) + inserted + Array(units[start..<end]) + inserted + Array(units[end...])
      return Edit(text: Self.string(edited), selectionStart: start + inserted.count, selectionEnd: end + inserted.count)
    }
    let newline = UInt16(UInt8(ascii: "\n"))
    let searchFrom = max(start - 1, 0)
    let lineStart = units.isEmpty ? 0 : (units[...min(searchFrom, units.count - 1)].lastIndex(of: newline).map { $0 + 1 } ?? 0)
    let inserted = Array(prefix.utf16)
    let edited = Array(units[..<lineStart]) + inserted + Array(units[lineStart...])
    return Edit(text: Self.string(edited), selectionStart: start + inserted.count, selectionEnd: end + inserted.count)
  }

  private static func string(_ units: [UInt16]) -> String {
    String(decoding: units, as: UTF16.self)
  }
}
