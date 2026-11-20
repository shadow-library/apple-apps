import ShadowText

enum ProseRegex {
  static func literal(_ source: String, _ flags: String = "") -> JSRegex {
    do {
      return try JSRegex(source, flags: flags)
    } catch {
      preconditionFailure("the reference pattern /\(source)/\(flags) does not compile: \(error)")
    }
  }

  static let whitespaceRun = literal(#"\s+"#)
  static let whitespaceRunGlobal = literal(#"\s+"#, "g")
}
