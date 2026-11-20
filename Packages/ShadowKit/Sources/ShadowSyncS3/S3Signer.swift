import CryptoKit
import Foundation

struct S3SignableRequest: Sendable {
  var method: String
  var host: String
  var path: String
  var query: [(name: String, value: String)]
  var headers: [String: String]
  var payloadHash: String

  var canonicalURI: String {
    path.isEmpty ? "/" : S3URIEncoding.encode(path, keepingSlashes: true)
  }

  var canonicalQuery: String {
    query.map { (S3URIEncoding.encode($0.name, keepingSlashes: false), S3URIEncoding.encode($0.value, keepingSlashes: false)) }
      .sorted { $0.0 == $1.0 ? $0.1.utf8.lexicographicallyPrecedes($1.1.utf8) : $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
      .map { "\($0.0)=\($0.1)" }
      .joined(separator: "&")
  }
}

struct S3Signer: Sendable {
  static let algorithm = "AWS4-HMAC-SHA256"
  static let service = "s3"
  static let emptyPayloadHash = hexSHA256(Data())

  let credentials: S3Credentials
  let region: String

  func authorizedHeaders(for request: S3SignableRequest, at date: Date) -> [String: String] {
    let stamp = S3Timestamp(date)
    var signed = request
    signed.headers["x-amz-date"] = stamp.dateTime
    signed.headers["x-amz-content-sha256"] = request.payloadHash
    if let sessionToken = credentials.sessionToken { signed.headers["x-amz-security-token"] = sessionToken }
    let names = signedHeaderNames(signed)
    let credential = "\(credentials.accessKeyID)/\(scope(stamp))"
    var headers = signed.headers
    headers["Authorization"] = "\(Self.algorithm) Credential=\(credential),SignedHeaders=\(names),Signature=\(signature(signed, at: stamp))"
    return headers
  }

  func canonicalRequest(_ request: S3SignableRequest) -> String {
    let headers = canonicalHeaders(request)
    return [
      request.method, request.canonicalURI, request.canonicalQuery,
      headers.map { "\($0.name):\($0.value)\n" }.joined(), headers.map(\.name).joined(separator: ";"), request.payloadHash,
    ].joined(separator: "\n")
  }

  func stringToSign(_ request: S3SignableRequest, at stamp: S3Timestamp) -> String {
    [Self.algorithm, stamp.dateTime, scope(stamp), Self.hexSHA256(Data(canonicalRequest(request).utf8))].joined(separator: "\n")
  }

  func signature(_ request: S3SignableRequest, at stamp: S3Timestamp) -> String {
    let dateKey = Self.hmac(key: SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8)), stamp.date)
    let signingKey = [region, Self.service, "aws4_request"].reduce(dateKey) { Self.hmac(key: $0, $1) }
    return Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign(request, at: stamp).utf8), using: signingKey))
  }

  static func hexSHA256(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
  }

  private func scope(_ stamp: S3Timestamp) -> String {
    "\(stamp.date)/\(region)/\(Self.service)/aws4_request"
  }

  private func signedHeaderNames(_ request: S3SignableRequest) -> String {
    canonicalHeaders(request).map(\.name).joined(separator: ";")
  }

  private func canonicalHeaders(_ request: S3SignableRequest) -> [(name: String, value: String)] {
    var headers = [(name: "host", value: request.host)]
    for (name, value) in request.headers where name.lowercased() != "host" { headers.append((name.lowercased(), Self.canonicalValue(value))) }
    return headers.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
  }

  private static func canonicalValue(_ value: String) -> String {
    value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
  }

  private static func hmac(key: SymmetricKey, _ message: String) -> SymmetricKey {
    SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
  }

  private static func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}

struct S3Timestamp: Sendable, Equatable {
  let date: String
  let dateTime: String

  init(_ instant: Date) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
    func padded(_ value: Int?, _ width: Int) -> String {
      let text = String(value ?? 0)
      return String(repeating: "0", count: max(0, width - text.count)) + text
    }
    date = padded(parts.year, 4) + padded(parts.month, 2) + padded(parts.day, 2)
    dateTime = date + "T" + padded(parts.hour, 2) + padded(parts.minute, 2) + padded(parts.second, 2) + "Z"
  }
}

enum S3URIEncoding {
  static func encode(_ text: String, keepingSlashes: Bool) -> String {
    var encoded = ""
    encoded.reserveCapacity(text.utf8.count)
    for byte in text.utf8 {
      if isUnreserved(byte) || (keepingSlashes && byte == UInt8(ascii: "/")) {
        encoded.unicodeScalars.append(Unicode.Scalar(byte))
      } else {
        encoded += String(format: "%%%02X", byte)
      }
    }
    return encoded
  }

  static func decode(_ text: String, plusAsSpace: Bool) -> String? {
    var bytes: [UInt8] = []
    var iterator = Array(text.utf8).makeIterator()
    while let byte = iterator.next() {
      switch byte {
      case UInt8(ascii: "%"):
        guard let high = iterator.next().flatMap(hexValue), let low = iterator.next().flatMap(hexValue) else { return nil }
        bytes.append(high << 4 | low)
      case UInt8(ascii: "+") where plusAsSpace:
        bytes.append(UInt8(ascii: " "))
      default:
        bytes.append(byte)
      }
    }
    return String(validating: bytes, as: UTF8.self)
  }

  private static func isUnreserved(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): true
    case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"): true
    default: false
    }
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
    default: nil
    }
  }
}
