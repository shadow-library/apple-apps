import Foundation

enum GeneratorError: Error, CustomStringConvertible {
  case unreadableInput(path: String, reason: String)
  case unsupportedThemes([String])
  case missingThemeValue(token: String)
  case unknownAlias(String, referencedBy: String)
  case cyclicAlias([String])
  case invalidColor(String, token: String)
  case invalidNumber(String, token: String)
  case invalidShadow(String, token: String)
  case tooManyShadowLayers(token: String, count: Int)
  case invalidIdentifier(String, token: String)
  case duplicateIdentifier(String, tokens: [String])

  var description: String {
    switch self {
    case .unreadableInput(let path, let reason): "Cannot read \(path): \(reason)"
    case .unsupportedThemes(let themes): "Expected the themes light and dark, found \(themes.joined(separator: ", "))"
    case .missingThemeValue(let token): "\(token) needs a value for both light and dark"
    case .unknownAlias(let alias, let token): "\(token) references the unknown token {\(alias)}"
    case .cyclicAlias(let chain): "Alias cycle: \(chain.joined(separator: " -> "))"
    case .invalidColor(let value, let token): "\(token) has an unsupported colour value \"\(value)\""
    case .invalidNumber(let value, let token): "\(token) has an unsupported number \"\(value)\""
    case .invalidShadow(let value, let token): "\(token) has an unsupported shadow \"\(value)\""
    case .tooManyShadowLayers(let token, let count): "\(token) has \(count) layers; ShadowElevation applies at most \(Generator.maximumShadowLayers)"
    case .invalidIdentifier(let identifier, let token): "\(token) maps to \"\(identifier)\", which is not a usable Swift identifier"
    case .duplicateIdentifier(let identifier, let tokens): "\(tokens.joined(separator: " and ")) both map to \"\(identifier)\""
    }
  }
}

enum Theme: String, CaseIterable {
  case light
  case dark
}

enum TokenValue: Decodable {
  case shared(String)
  case themed(light: String, dark: String)

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self = .shared(value)
      return
    }
    let values = try container.decode([String: String].self)
    guard let light = values[Theme.light.rawValue], let dark = values[Theme.dark.rawValue] else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Themed values need light and dark")
    }
    self = .themed(light: light, dark: dark)
  }

  func value(for theme: Theme) -> String {
    switch self {
    case .shared(let value): value
    case .themed(let light, let dark): theme == .light ? light : dark
    }
  }
}

struct SourceToken: Decodable {
  let name: String
  let value: TokenValue
  let usage: String?
}

struct ThemeDeclaration: Decodable {
  let id: String
}

struct ColorGroup: Decodable {
  let themes: [ThemeDeclaration]
  let tokens: [SourceToken]
}

struct TokenGroup: Decodable {
  let tokens: [SourceToken]
}

struct TokenFile: Decodable {
  let color: ColorGroup
  let spacing: TokenGroup
  let radius: TokenGroup
  let shadow: TokenGroup
  let size: TokenGroup
  let opacity: TokenGroup
}

struct RGBA: Equatable {
  let red: Int
  let green: Int
  let blue: Int
  let alpha: Double

  var swiftLiteral: String {
    let hex = String(format: "0x%02lX%02lX%02lX", red, green, blue)
    return alpha == 1 ? "ShadowRGBA(hex: \(hex))" : "ShadowRGBA(hex: \(hex), alpha: \(numberLiteral(alpha)))"
  }

  init(red: Int, green: Int, blue: Int, alpha: Double) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  init(parsing text: String, token: String) throws(GeneratorError) {
    let value = text.trimmingCharacters(in: .whitespaces).lowercased()
    if value.hasPrefix("#") {
      try self.init(hex: String(value.dropFirst()), original: text, token: token)
    } else if let arguments = functionArguments(value, names: ["rgba", "rgb"]) {
      try self.init(rgbArguments: arguments, original: text, token: token)
    } else {
      throw .invalidColor(text, token: token)
    }
  }

  private init(hex: String, original: String, token: String) throws(GeneratorError) {
    let digits = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
    guard digits.count == 6 || digits.count == 8, let packed = UInt64(digits, radix: 16) else { throw .invalidColor(original, token: token) }
    let channels = digits.count == 8 ? packed >> 8 : packed
    let alpha = digits.count == 8 ? Double(packed & 0xFF) / 255 : 1
    self.init(red: Int(channels >> 16 & 0xFF), green: Int(channels >> 8 & 0xFF), blue: Int(channels & 0xFF), alpha: alpha)
  }

  private init(rgbArguments arguments: [String], original: String, token: String) throws(GeneratorError) {
    guard arguments.count == 3 || arguments.count == 4 else { throw .invalidColor(original, token: token) }
    let channels = arguments.prefix(3).compactMap { Int($0) }.filter { (0...255).contains($0) }
    let alpha = arguments.count == 4 ? Double(arguments[3]) : 1
    guard channels.count == 3, let alpha, (0...1).contains(alpha) else { throw .invalidColor(original, token: token) }
    self.init(red: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
  }
}

struct ShadowLayer {
  let color: RGBA
  let x: Double
  let y: Double
  let blur: Double
  let spread: Double

  var swiftLiteral: String {
    let lengths = "x: \(numberLiteral(x)), y: \(numberLiteral(y)), blur: \(numberLiteral(blur)), spread: \(numberLiteral(spread))"
    return "Layer(color: \(color.swiftLiteral), \(lengths))"
  }
}

struct ColorToken {
  let identifier: String
  let name: String
  let usage: String?
  let light: RGBA
  let dark: RGBA
}

struct ScalarToken {
  let identifier: String
  let name: String
  let usage: String?
  let literal: String
}

struct ElevationToken {
  let identifier: String
  let usage: String?
  let light: [ShadowLayer]
  let dark: [ShadowLayer]
}

enum Generator {
  static let maximumShadowLayers = 2
  static let docCommentWidth = 140
  static let header = "// Generated from Design/tokens.json by Scripts/generate-design-tokens.swift. Do not edit; run `mise run tokens`."
  static let swiftKeywords: Set<String> = [
    "as", "associatedtype", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
    "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil",
    "operator", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "static", "struct", "subscript", "super", "switch",
    "throw", "throws", "true", "try", "typealias", "var", "where", "while",
  ]
}

func numberLiteral(_ value: Double) -> String {
  value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : "\(value)"
}

func functionArguments(_ value: String, names: [String]) -> [String]? {
  for name in names where value.hasPrefix("\(name)(") && value.hasSuffix(")") {
    let inner = value.dropFirst(name.count + 1).dropLast()
    return inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
  }
  return nil
}

func aliasTarget(_ value: String) -> String? {
  let trimmed = value.trimmingCharacters(in: .whitespaces)
  guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
  return String(trimmed.dropFirst().dropLast())
}

func parseNumber(_ value: String, token: String) throws(GeneratorError) -> Double {
  let trimmed = value.trimmingCharacters(in: .whitespaces)
  let digits = trimmed.hasSuffix("px") ? String(trimmed.dropLast(2)) : trimmed
  guard let number = Double(digits), number.isFinite else { throw .invalidNumber(value, token: token) }
  return number
}

func identifier(for name: String, groupWord: String? = nil) throws(GeneratorError) -> String {
  var words = name.split(separator: "-").map(String.init)
  if let groupWord, words.count > 1 {
    if words.first == groupWord {
      words.removeFirst()
    } else if words.last == groupWord {
      words.removeLast()
    }
    if let first = words.first, let multiplier = first.firstIndex(of: "x"), let count = Int(first[..<multiplier]) {
      words[0] = String(repeating: "x", count: count) + first[multiplier...].dropFirst()
    }
    if words.first?.first?.isNumber == true {
      words.insert(groupWord, at: 0)
    }
  }
  let identifier = words.enumerated().map { index, word in index == 0 ? word : word.prefix(1).uppercased() + word.dropFirst() }.joined()
  let isValid = identifier.first?.isLowercase == true && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
  guard isValid, !Generator.swiftKeywords.contains(identifier) else { throw .invalidIdentifier(identifier, token: name) }
  return identifier
}

func requireUniqueIdentifiers(_ pairs: [(identifier: String, name: String)]) throws(GeneratorError) {
  var seen: [String: String] = [:]
  for pair in pairs {
    if let existing = seen[pair.identifier] { throw .duplicateIdentifier(pair.identifier, tokens: [existing, pair.name]) }
    seen[pair.identifier] = pair.name
  }
}

func isPrimitive(_ token: SourceToken) -> Bool {
  guard case .shared(let value) = token.value, aliasTarget(value) == nil else { return false }
  guard let step = token.name.split(separator: "-").last, token.name.contains("-") else { return false }
  return Int(step) != nil || step == "white" || step == "black"
}

struct ColorResolver {
  let sources: [String: TokenValue]

  func resolve(_ name: String, theme: Theme, chain: [String] = []) throws(GeneratorError) -> RGBA {
    guard !chain.contains(name) else { throw .cyclicAlias(chain + [name]) }
    guard let source = sources[name] else { throw .unknownAlias(name, referencedBy: chain.last ?? name) }
    let value = source.value(for: theme)
    if let target = aliasTarget(value) { return try resolve(target, theme: theme, chain: chain + [name]) }
    return try RGBA(parsing: value, token: name)
  }
}

func colorTokens(from group: ColorGroup, resolver: ColorResolver) throws(GeneratorError) -> [ColorToken] {
  let themeIDs = group.themes.map(\.id)
  guard Set(themeIDs) == Set(Theme.allCases.map(\.rawValue)), themeIDs.count == Theme.allCases.count else { throw .unsupportedThemes(themeIDs) }
  var tokens: [ColorToken] = []
  for source in group.tokens {
    let light = try resolver.resolve(source.name, theme: .light)
    let dark = try resolver.resolve(source.name, theme: .dark)
    guard !isPrimitive(source) else { continue }
    tokens.append(ColorToken(identifier: try identifier(for: source.name), name: source.name, usage: source.usage, light: light, dark: dark))
  }
  try requireUniqueIdentifiers(tokens.map { ($0.identifier, $0.name) })
  return tokens
}

func scalarTokens(from group: TokenGroup, groupWord: String) throws(GeneratorError) -> [ScalarToken] {
  var tokens: [ScalarToken] = []
  for source in group.tokens {
    guard case .shared(let value) = source.value else { throw .invalidNumber("themed value", token: source.name) }
    let literal = numberLiteral(try parseNumber(value, token: source.name))
    tokens.append(ScalarToken(identifier: try identifier(for: source.name, groupWord: groupWord), name: source.name, usage: source.usage, literal: literal))
  }
  try requireUniqueIdentifiers(tokens.map { ($0.identifier, $0.name) })
  return tokens
}

func splitTopLevel(_ value: String, separator: Character) -> [String] {
  var parts: [String] = []
  var current = ""
  var depth = 0
  for character in value {
    if character == "(" { depth += 1 }
    if character == ")" { depth -= 1 }
    if character == separator && depth == 0 {
      parts.append(current)
      current = ""
    } else {
      current.append(character)
    }
  }
  parts.append(current)
  return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

func shadowLayers(_ value: String, token: String, resolver: ColorResolver, theme: Theme) throws(GeneratorError) -> [ShadowLayer] {
  if value.trimmingCharacters(in: .whitespaces) == "none" { return [] }
  var layers: [ShadowLayer] = []
  for layer in splitTopLevel(value, separator: ",") {
    let parts = splitTopLevel(layer, separator: " ")
    guard let colorText = parts.last, (3...5).contains(parts.count) else { throw .invalidShadow(value, token: token) }
    let lengths = try parts.dropLast().map { part throws(GeneratorError) in try parseNumber(part, token: token) }
    let color = try shadowColor(colorText, token: token, resolver: resolver, theme: theme)
    let spread = lengths.count == 4 ? lengths[3] : 0
    layers.append(ShadowLayer(color: color, x: lengths[0], y: lengths[1], blur: lengths.count > 2 ? lengths[2] : 0, spread: spread))
  }
  guard layers.count <= Generator.maximumShadowLayers else { throw .tooManyShadowLayers(token: token, count: layers.count) }
  return layers
}

func shadowColor(_ value: String, token: String, resolver: ColorResolver, theme: Theme) throws(GeneratorError) -> RGBA {
  guard let alias = aliasTarget(value) else { return try RGBA(parsing: value, token: token) }
  return try resolver.resolve(alias, theme: theme)
}

func elevationTokens(from group: TokenGroup, resolver: ColorResolver) throws(GeneratorError) -> [ElevationToken] {
  var tokens: [ElevationToken] = []
  for source in group.tokens {
    let light = try shadowLayers(source.value.value(for: .light), token: source.name, resolver: resolver, theme: .light)
    let dark = try shadowLayers(source.value.value(for: .dark), token: source.name, resolver: resolver, theme: .dark)
    tokens.append(ElevationToken(identifier: try identifier(for: source.name, groupWord: "shadow"), usage: source.usage, light: light, dark: dark))
  }
  try requireUniqueIdentifiers(zip(tokens.map(\.identifier), group.tokens.map(\.name)).map { ($0, $1) })
  return tokens
}

func docComment(_ text: String?, indent: String) -> [String] {
  guard let text, !text.isEmpty else { return [] }
  var lines: [String] = []
  var current = ""
  for word in text.split(separator: " ") {
    if !current.isEmpty && current.count + word.count + 1 > Generator.docCommentWidth {
      lines.append(current)
      current = ""
    }
    current += current.isEmpty ? String(word) : " \(word)"
  }
  lines.append(current)
  return lines.map { "\(indent)/// \($0)" }
}

func collectionElements(_ elements: [String], indent: String) -> [String] {
  let separator = elements.count > 1 ? "," : ""
  return elements.map { "\(indent)\($0)\(separator)" }
}

func file(imports: [String], body: [String]) -> String {
  let importLines = imports.isEmpty ? [] : imports.map { "import \($0)" } + [""]
  return ([Generator.header, ""] + importLines + body).joined(separator: "\n") + "\n"
}

func colorTokenFile(_ tokens: [ColorToken]) -> String {
  func table(_ property: String, _ value: (ColorToken) -> RGBA) -> [String] {
    ["  public var \(property): ShadowRGBA {", "    switch self {"]
      + tokens.map { "    case .\($0.identifier): \(value($0).swiftLiteral)" }
      + ["    }", "  }"]
  }
  var body = ["nonisolated public enum ShadowColorToken: String, CaseIterable, Sendable {"]
  body += tokens.map { "  case \($0.identifier) = \"\($0.name)\"" }
  body += [""] + table("light", \.light) + [""] + table("dark", \.dark) + ["}"]
  return file(imports: [], body: body)
}

func colorNamespaceFile(_ tokens: [ColorToken]) -> String {
  var body = ["nonisolated public enum ShadowColor {"]
  for (index, token) in tokens.enumerated() {
    if index > 0 { body.append("") }
    body += docComment(token.usage, indent: "  ")
    body.append("  public static let \(token.identifier): Color = ShadowColorToken.\(token.identifier).color")
  }
  body.append("}")
  return file(imports: ["SwiftUI"], body: body)
}

func scalarFile(typeName: String, swiftType: String, tokens: [ScalarToken]) -> String {
  var body = ["nonisolated public enum \(typeName) {"]
  for token in tokens {
    body += docComment(token.usage, indent: "  ")
    body.append("  public static let \(token.identifier): \(swiftType) = \(token.literal)")
    body.append("")
  }
  body.append("  public static let tokens: [ShadowScalarToken] = [")
  body += collectionElements(tokens.map { "ShadowScalarToken(name: \"\($0.name)\", value: \($0.identifier))" }, indent: "    ")
  body += ["  ]", "}"]
  return file(imports: ["CoreGraphics"], body: body)
}

func elevationFile(_ tokens: [ElevationToken]) -> String {
  func layers(_ label: String, _ layers: [ShadowLayer]) -> [String] {
    guard !layers.isEmpty else { return ["    \(label): []"] }
    return ["    \(label): ["] + collectionElements(layers.map(\.swiftLiteral), indent: "      ") + ["    ]"]
  }
  var body = ["nonisolated extension ShadowElevation {"]
  for (index, token) in tokens.enumerated() {
    if index > 0 { body.append("") }
    body += docComment(token.usage, indent: "  ")
    body.append("  public static let \(token.identifier) = ShadowElevation(")
    var arguments = layers("light", token.light)
    arguments[arguments.count - 1] += ","
    body += arguments + layers("dark", token.dark) + ["  )"]
  }
  body.append("}")
  return file(imports: ["CoreGraphics"], body: body)
}

func generate(root: URL) throws -> [String: String] {
  let inputURL = root.appending(path: "Design/tokens.json")
  let data: Data
  do {
    data = try Data(contentsOf: inputURL)
  } catch {
    throw GeneratorError.unreadableInput(path: inputURL.path, reason: error.localizedDescription)
  }
  let tokens = try JSONDecoder().decode(TokenFile.self, from: data)
  let resolver = ColorResolver(sources: Dictionary(tokens.color.tokens.map { ($0.name, $0.value) }) { first, _ in first })
  let colors = try colorTokens(from: tokens.color, resolver: resolver)
  return [
    "ShadowColor.swift": colorNamespaceFile(colors),
    "ShadowColorToken.swift": colorTokenFile(colors),
    "Spacing.swift": scalarFile(typeName: "Spacing", swiftType: "CGFloat", tokens: try scalarTokens(from: tokens.spacing, groupWord: "space")),
    "Radius.swift": scalarFile(typeName: "Radius", swiftType: "CGFloat", tokens: try scalarTokens(from: tokens.radius, groupWord: "radius")),
    "ShadowMetrics.swift": scalarFile(typeName: "ShadowMetrics", swiftType: "CGFloat", tokens: try scalarTokens(from: tokens.size, groupWord: "size")),
    "ShadowOpacity.swift": scalarFile(typeName: "ShadowOpacity", swiftType: "Double", tokens: try scalarTokens(from: tokens.opacity, groupWord: "opacity")),
    "ShadowElevation+Tokens.swift": elevationFile(try elevationTokens(from: tokens.shadow, resolver: resolver)),
  ]
}

func write(_ files: [String: String], to directory: URL) throws {
  let manager = FileManager.default
  try manager.createDirectory(at: directory, withIntermediateDirectories: true)
  let stale = try manager.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") && files[$0] == nil }
  for name in stale.sorted() {
    try manager.removeItem(at: directory.appending(path: name))
    print("removed \(name)")
  }
  for (name, contents) in files.sorted(by: { $0.key < $1.key }) {
    let url = directory.appending(path: name)
    let current = try? String(contentsOf: url, encoding: .utf8)
    guard current != contents else { continue }
    try contents.write(to: url, atomically: true, encoding: .utf8)
    print("wrote \(name)")
  }
}

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let outputDirectory = root.appending(path: "Packages/ShadowKit/Sources/ShadowDesignSystem/Tokens/Generated")

do {
  try write(try generate(root: root), to: outputDirectory)
} catch {
  FileHandle.standardError.write(Data("generate-design-tokens: \(error)\n".utf8))
  exit(1)
}
