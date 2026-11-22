import Foundation
import OSLog

/// One log entry as the report reads it: its message kept as the format's text and each argument with the placeholder it was logged under.
nonisolated struct DiagnosticsLogEntry: Sendable, Hashable {
  enum Argument: Sendable, Hashable {
    case none
    case text(String?)
    case number(String?)
    case undecodable
  }

  struct Piece: Sendable, Hashable {
    let text: String
    let placeholder: String
    let argument: Argument
  }

  let date: Date
  let level: String
  let subsystem: String
  let category: String
  let pieces: [Piece]

  /// A text logged `.public` and a number logged without a privacy are shown, as the system shows them; anything else, or any value that is also marked
  /// private, sensitive or masked, is `<private>`.
  var message: String {
    pieces.map { $0.text.replacing("%%", with: "%") + Self.render($0) }.joined()
  }

  private static func render(_ piece: Piece) -> String {
    guard !piece.placeholder.isEmpty else { return "" }
    let flags = privacyFlags(of: piece.placeholder)
    let isPublic = flags.contains("public")
    let isPrivate = flags.contains("private") || flags.contains("sensitive") || flags.contains { $0.hasPrefix("mask") }
    switch piece.argument {
    case .text(let value?) where isPublic && !isPrivate: return value
    case .number(let value?) where !isPrivate: return value
    case .none, .text, .number, .undecodable: return "<private>"
    }
  }

  private static func privacyFlags(of placeholder: String) -> [String] {
    guard let open = placeholder.firstIndex(of: "{"), let close = placeholder[open...].firstIndex(of: "}") else { return [] }
    return placeholder[placeholder.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
  }
}

/// The app's own log lines from this process over a recent span, read from the unified log, oldest first.
nonisolated enum DiagnosticsLog {
  static let span: TimeInterval = 24 * 60 * 60
  static let entryLimit = 5_000
  static let lineLimit = 2_000

  struct Read: Sendable, Equatable {
    let lines: [String]
    let dropped: Int
  }

  typealias Source = @Sendable (_ subsystems: Set<String>, _ since: Date) throws(DiagnosticsError) -> [DiagnosticsLogEntry]

  /// The entries of `subsystems` at or after `since`, each once, at most `limit` of them (the latest), each line cut to `lineLimit` characters. The
  /// unified log can hand the same entry back twice while it is being written to.
  static func lines(of entries: [DiagnosticsLogEntry], subsystems: Set<String>, since: Date, limit: Int = entryLimit) -> Read {
    var seen = Set<DiagnosticsLogEntry>()
    let kept = entries.filter { subsystems.contains($0.subsystem) && $0.date >= since && seen.insert($0).inserted }
    let latest = kept.suffix(limit)
    return Read(lines: latest.map(line), dropped: kept.count - latest.count)
  }

  static func line(_ entry: DiagnosticsLogEntry) -> String {
    let stamp = entry.date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    let line = "\(stamp) \(entry.level) [\(entry.category)] \(entry.message)"
    return line.count > lineLimit ? String(line.prefix(lineLimit)) + "…" : line
  }

  /// This process's entries in the unified log; the predicate narrows the read, and `lines` filters again by subsystem and date.
  static let unifiedLog: Source = { subsystems, since throws(DiagnosticsError) in
    let store: OSLogStore
    let entries: AnySequence<OSLogEntry>
    do {
      store = try OSLogStore(scope: .currentProcessIdentifier)
      entries = try store.getEntries(at: store.position(date: since), matching: NSPredicate(format: "subsystem IN %@", Array(subsystems)))
    } catch {
      throw .logUnavailable(String(describing: type(of: error)))
    }
    return entries.compactMap { $0 as? OSLogEntryLog }.map(DiagnosticsLogEntry.init)
  }
}

extension DiagnosticsLogEntry {
  /// The composed message carries private values in plain text while the device has private logging turned on, so it is never read; the message is
  /// rebuilt from the format and the arguments its placeholders allow.
  nonisolated init(_ entry: OSLogEntryLog) {
    let pieces = entry.components.map { Piece(text: $0.formatSubstring, placeholder: $0.placeholder, argument: Argument($0)) }
    self.init(
      date: entry.date, level: Self.level(entry.level), subsystem: entry.subsystem, category: entry.category,
      pieces: pieces.isEmpty ? Self.unsplit(entry.formatString) : pieces)
  }

  /// A format the log did not split into components is kept only when it has no placeholder.
  private nonisolated static func unsplit(_ format: String) -> [Piece] {
    guard format.replacing("%%", with: "").contains("%") else { return [Piece(text: format, placeholder: "", argument: .none)] }
    return [Piece(text: "", placeholder: "%", argument: .none)]
  }

  private nonisolated static func level(_ level: OSLogEntryLog.Level) -> String {
    switch level {
    case .debug: "debug"
    case .info: "info"
    case .notice: "notice"
    case .error: "error"
    case .fault: "fault"
    case .undefined: "default"
    @unknown default: "default"
    }
  }
}

extension DiagnosticsLogEntry.Argument {
  nonisolated init(_ component: OSLogMessageComponent) {
    switch component.argumentCategory {
    case .string: self = .text(component.argumentStringValue)
    case .int64, .uInt64, .double: self = .number(component.argumentNumberValue?.stringValue)
    case .data, .undefined: self = .undecodable
    @unknown default: self = .undecodable
    }
  }
}
