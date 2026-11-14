import Foundation

extension JSONDecoder {
  /// The platform servers emit ISO 8601 dates with milliseconds, which `.iso8601` rejects, so both forms are accepted.
  public static func shadow() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let string = try container.decode(String.self)
      if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
      if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date, got \(string)")
    }
    return decoder
  }
}

extension JSONEncoder {
  public static func shadow() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
    return encoder
  }
}
