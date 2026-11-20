import Foundation

struct S3XMLNode: Sendable, Equatable {
  let name: String
  var text: String
  var children: [S3XMLNode]

  func child(_ name: String) -> S3XMLNode? {
    children.first { $0.name == name }
  }

  func children(_ name: String) -> [S3XMLNode] {
    children.filter { $0.name == name }
  }

  func value(_ name: String) -> String? {
    child(name)?.text
  }

  static func parse(_ data: Data) -> S3XMLNode? {
    guard !data.isEmpty else { return nil }
    let parser = XMLParser(data: data)
    let builder = TreeBuilder()
    parser.delegate = builder
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    guard parser.parse() else { return nil }
    return builder.root
  }

  static func escape(_ text: String) -> String {
    var escaped = ""
    for character in text {
      switch character {
      case "&": escaped += "&amp;"
      case "<": escaped += "&lt;"
      case ">": escaped += "&gt;"
      case "\"": escaped += "&quot;"
      case "'": escaped += "&apos;"
      default: escaped.append(character)
      }
    }
    return escaped
  }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
  private var stack: [S3XMLNode] = []
  private(set) var root: S3XMLNode?

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
    stack.append(S3XMLNode(name: elementName, text: "", children: []))
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard !stack.isEmpty else { return }
    stack[stack.count - 1].text += string
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
    guard let node = stack.popLast() else { return }
    if stack.isEmpty {
      root = node
    } else {
      stack[stack.count - 1].children.append(node)
    }
  }
}
