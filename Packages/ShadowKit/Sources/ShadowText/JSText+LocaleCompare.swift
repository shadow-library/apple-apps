import Foundation

private let collationLocale = Locale(identifier: "en_US")

extension JSText {
  /// `String.prototype.localeCompare` under the en-US ICU collation the reference fixtures ran with, two strings the collation calls equal ordered by code unit.
  /// Residual risk: Foundation's collation follows the OS's ICU, which can reorder some scripts or symbols between OS versions.
  public static func localePrecedes(_ left: String, _ right: String) -> Bool {
    switch left.compare(right, options: [], range: nil, locale: collationLocale) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: codeUnitPrecedes(left, right)
    }
  }
}
