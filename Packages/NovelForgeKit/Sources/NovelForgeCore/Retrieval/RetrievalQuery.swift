import Foundation

/// An FTS5 MATCH expression built from free text that a model or the author wrote, so no FTS5 syntax in it is ever interpreted: every term becomes a quoted
/// string, the terms are OR'ed so a hit needs only one of them, and the whole query as one phrase lifts the passages that hold it verbatim.
struct RetrievalQuery: Sendable, Equatable {
  static let maximumTerms = 64

  let terms: [String]

  /// Splits where the `unicode61` tokenizer does by default: letters, numbers, private-use characters and the marks on them form terms.
  init(_ text: String) {
    var terms: [String] = []
    var seen = Set<String>()
    var term = String.UnicodeScalarView()
    func close() {
      guard !term.isEmpty else { return }
      let closed = String(term)
      term = String.UnicodeScalarView()
      if terms.count < Self.maximumTerms, seen.insert(closed.lowercased()).inserted { terms.append(closed) }
    }
    for scalar in text.unicodeScalars {
      if Self.isTermScalar(scalar) {
        term.append(scalar)
      } else {
        close()
      }
    }
    close()
    self.terms = terms
  }

  var matchExpression: String? {
    guard !terms.isEmpty else { return nil }
    let quoted = terms.map(Self.quoted)
    guard terms.count > 1 else { return quoted[0] }
    return ([Self.quoted(terms.joined(separator: " "))] + quoted).joined(separator: " OR ")
  }

  private static func quoted(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  private static func isTermScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
    case .decimalNumber, .letterNumber, .otherNumber: true
    case .nonspacingMark, .spacingMark, .enclosingMark: true
    case .privateUse: true
    default: false
    }
  }
}
