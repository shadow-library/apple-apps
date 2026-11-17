// apps/novel-forge-server/src/modules/ledger/ledger-sections.ts:16
public enum NotebookTopics {
  public static let authorBrief = "start.brief"
  public static let ideaPrefix = "idea."

  public static func idea(_ ideaId: String) -> String { ideaPrefix + ideaId }

  // ledger-sections.ts:26
  public static func isReserved(_ topic: String) -> Bool {
    topic.utf8.elementsEqual(authorBrief.utf8) || isProgress(topic) || topic.utf8.starts(with: ideaPrefix.utf8)
  }

  // ledger.controller.ts:24
  public static func isVisibleInNotebook(_ topic: String) -> Bool {
    !topic.utf8.elementsEqual(authorBrief.utf8) && !isProgress(topic)
  }

  // ledger.types.ts:6 /^[a-z0-9][a-z0-9_.-]{0,99}$/
  public static func isKey(_ topic: String) -> Bool {
    let bytes = Array(topic.utf8)
    guard let first = bytes.first, bytes.count <= NotebookLimits.topic, isLowercaseOrDigit(first) else { return false }
    return bytes.dropFirst().allSatisfy { isLowercaseOrDigit($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }
  }

  // ledger-entries.ts:19
  public static func matches(_ topic: String, pattern: String) -> Bool {
    guard pattern.utf8.count >= 2, pattern.utf8.suffix(2).elementsEqual(".*".utf8) else { return topic.utf8.elementsEqual(pattern.utf8) }
    return topic.utf8.starts(with: pattern.utf8.dropLast())
  }

  private static func isProgress(_ topic: String) -> Bool {
    topic.utf8.starts(with: progressTopicPrefix.utf8)
  }

  private static func isLowercaseOrDigit(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
  }
}
