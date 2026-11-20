import CryptoKit
import Foundation
import ShadowNetworking
import Synchronization

@testable import ShadowSyncS3

final class FakeS3Service: HTTPTransport {
  struct Options: Sendable {
    var endpointHost = "s3.test.example"
    var region = "eu-west-1"
    var bucket = "shadow-vaults"
    var style = S3Configuration.AddressingStyle.virtualHosted
    var accessKeyID = "AKIAFAKEEXAMPLE"
    var secretAccessKey = "fake/secret+KEY"
    var sessionToken: String?
    var honorsConditionalWrites = true
    var refusesConditionalWritesAsUnimplemented = false
    var pageSize = 7
    var honorsEncodingType = true
    var truncatesWithoutToken = false
    var listsInReverse = false
    var bucketExists = true
    var serverDate = Date(timeIntervalSince1970: 1_772_366_400)
  }

  enum Operation: Sendable, Equatable {
    case list
    case get
    case head
    case put
    case delete
  }

  struct Fault: Sendable {
    var operation: Operation?
    var status: Int
    var code: String?
    var message: String?
    var headers: [String: String] = [:]
    var transportError: URLError?
    var remaining = 1
    var skip = 0
  }

  struct Exchange: Sendable {
    let operation: Operation
    let objectName: String?
    let query: [String: String]
    let headers: [String: String]
    let body: Data
  }

  private struct State {
    var objects: [String: Data] = [:]
    var modified: [String: Date] = [:]
    var faults: [Fault] = []
    var perKeyDeleteErrors: [String: String] = [:]
    var violations: [String] = []
    var exchanges: [Exchange] = []
  }

  let options: Options
  private let state = Mutex(State())

  init(_ options: Options = Options()) {
    self.options = options
  }

  var violations: [String] { state.withLock { $0.violations } }
  var exchanges: [Exchange] { state.withLock { $0.exchanges } }
  var objectNames: [String] { state.withLock { $0.objects.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } } }

  func seed(_ name: String, _ data: Data = Data("foreign".utf8), lastModified: Date? = nil) {
    state.withLock { state in
      state.objects[name] = data
      state.modified[name] = lastModified ?? options.serverDate
    }
  }

  func object(_ name: String) -> Data? {
    state.withLock { $0.objects[name] }
  }

  func inject(_ fault: Fault) {
    state.withLock { $0.faults.append(fault) }
  }

  func failDelete(of name: String, code: String) {
    state.withLock { $0.perKeyDeleteErrors[name] = code }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard let url = request.url else { throw URLError(.badURL) }
    let headers = Dictionary((request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
    let body = request.httpBody ?? Data()
    guard let route = route(request, url: url) else { return try respond(url, status: 400, code: "InvalidURI", message: "Unroutable request") }
    let exchange = Exchange(operation: route.operation, objectName: route.objectName, query: route.query, headers: headers, body: body)
    state.withLock { $0.exchanges.append(exchange) }
    if let fault = takeFault(for: route.operation) {
      if let error = fault.transportError { throw error }
      return try respond(url, status: fault.status, code: route.operation == .head ? nil : fault.code, message: fault.message, headers: fault.headers)
    }
    if let failure = authenticate(request, url: url, headers: headers, body: body) { return try respond(url, status: 403, code: failure.code, message: failure.message) }
    guard options.bucketExists else { return try respond(url, status: 404, code: route.operation == .head ? nil : "NoSuchBucket", message: "The specified bucket does not exist") }
    switch route.operation {
    case .list: return try list(url, route.query)
    case .get: return try get(url, route.objectName ?? "")
    case .head: return try head(url, route.objectName ?? "")
    case .put: return try put(url, route.objectName ?? "", headers: headers, body: body)
    case .delete: return try delete(url, headers: headers, body: body)
    }
  }

  private func route(_ request: URLRequest, url: URL) -> (operation: Operation, objectName: String?, query: [String: String])? {
    let authority = Self.receivedHost(url)
    let path = url.path(percentEncoded: true)
    let query = Self.decodedQuery(url.query(percentEncoded: true))
    var objectPath: Substring
    switch options.style {
    case .virtualHosted:
      guard authority == "\(options.bucket).\(options.endpointHost)" else { return unroutable("virtual-hosted request to \(authority)") }
      objectPath = path.dropFirst()
    case .path:
      guard authority == options.endpointHost, path == "/\(options.bucket)" || path.hasPrefix("/\(options.bucket)/") else {
        return unroutable("path-style request to \(authority)\(path)")
      }
      objectPath = path.dropFirst(options.bucket.count + 2)
    }
    guard let objectName = Self.percentDecoded(String(objectPath)) else { return unroutable("undecodable path \(path)") }
    switch (request.httpMethod ?? "GET", objectName.isEmpty) {
    case ("GET", true) where query["list-type"] == "2": return (.list, nil, query)
    case ("POST", true) where query.keys.contains("delete"): return (.delete, nil, query)
    case ("GET", false): return (.get, objectName, query)
    case ("HEAD", false): return (.head, objectName, query)
    case ("PUT", false): return (.put, objectName, query)
    default: return unroutable("unexpected \(request.httpMethod ?? "nil") \(path)")
    }
  }

  private func authenticate(_ request: URLRequest, url: URL, headers: [String: String], body: Data) -> (code: String, message: String)? {
    if request.cachePolicy != .reloadIgnoringLocalAndRemoteCacheData { recordViolation("request may be answered from a cache") }
    guard let authorization = headers["authorization"], let parsed = Self.parseAuthorization(authorization) else {
      return violation("AccessDenied", "missing or malformed Authorization header")
    }
    guard parsed.accessKeyID == options.accessKeyID else { return ("InvalidAccessKeyId", "The AWS Access Key Id you provided does not exist in our records.") }
    guard let amzDate = headers["x-amz-date"], let signedAt = Self.parseAmzDate(amzDate) else { return violation("AccessDenied", "missing x-amz-date") }
    guard parsed.scope == "\(amzDate.prefix(8))/\(options.region)/s3/aws4_request" else { return violation("AuthorizationHeaderMalformed", "scope \(parsed.scope)") }
    guard headers["x-amz-content-sha256"] == Self.hex(SHA256.hash(data: body)) else { return violation("XAmzContentSHA256Mismatch", "payload hash differs from body") }
    guard parsed.signedHeaders == parsed.signedHeaders.sorted(), parsed.signedHeaders.allSatisfy({ $0 == $0.lowercased() }) else {
      return violation("AuthorizationHeaderMalformed", "signed headers not sorted lowercase: \(parsed.signedHeaders)")
    }
    let unsigned = headers.keys.filter { !["authorization", "content-length"].contains($0) && !parsed.signedHeaders.contains($0) }
    guard unsigned.isEmpty, parsed.signedHeaders.contains("host") else { return violation("AccessDenied", "unsigned headers \(unsigned.sorted())") }
    guard headers["x-amz-security-token"] == options.sessionToken else { return ("InvalidToken", "The provided token is malformed or otherwise invalid.") }
    if let length = headers["content-length"], Int(length) != body.count { return violation("BadRequest", "Content-Length \(length) for \(body.count) bytes") }
    guard abs(signedAt.timeIntervalSince(options.serverDate)) <= 900 else {
      return ("RequestTimeTooSkewed", "The difference between the request time and the current time is too large.")
    }
    let expected = signature(request, url: url, headers: headers, signedHeaders: parsed.signedHeaders, amzDate: amzDate)
    guard parsed.signature == expected else { return ("SignatureDoesNotMatch", "The request signature we calculated does not match the signature you provided.") }
    return nil
  }

  private func signature(_ request: URLRequest, url: URL, headers: [String: String], signedHeaders: [String], amzDate: String) -> String {
    let host = Self.receivedHost(url)
    let canonicalHeaders = signedHeaders.map { name in "\(name):\(name == "host" ? host : (headers[name] ?? "").trimmingCharacters(in: .whitespaces))\n" }.joined()
    let canonicalPath = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false)
      .map { Self.awsEncode(Self.percentDecoded(String($0)) ?? "") }
      .joined(separator: "/")
    let canonicalQuery = Self.decodedQuery(url.query(percentEncoded: true))
      .map { (Self.awsEncode($0.key), Self.awsEncode($0.value)) }
      .sorted { $0.0 < $1.0 }
      .map { "\($0.0)=\($0.1)" }
      .joined(separator: "&")
    let canonical = [
      request.httpMethod ?? "GET", canonicalPath.isEmpty ? "/" : canonicalPath, canonicalQuery, canonicalHeaders, signedHeaders.joined(separator: ";"),
      headers["x-amz-content-sha256"] ?? "",
    ].joined(separator: "\n")
    let scope = "\(amzDate.prefix(8))/\(options.region)/s3/aws4_request"
    let toSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(Self.hex(SHA256.hash(data: Data(canonical.utf8))))"
    var key = SymmetricKey(data: Data("AWS4\(options.secretAccessKey)".utf8))
    for part in [String(amzDate.prefix(8)), options.region, "s3", "aws4_request"] { key = SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)) }
    return Self.hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: key))
  }

  private func list(_ url: URL, _ query: [String: String]) throws -> (Data, HTTPURLResponse) {
    let prefix = query["prefix"] ?? ""
    let maxKeys = min(Int(query["max-keys"] ?? "1000") ?? 1000, options.pageSize)
    var after = query["start-after"] ?? ""
    if let token = query["continuation-token"] {
      guard token.hasPrefix("tok-"), let data = Data(base64Encoded: String(token.dropFirst(4))), let name = String(data: data, encoding: .utf8) else {
        return try respond(url, status: 400, code: "InvalidArgument", message: "The continuation token provided is incorrect")
      }
      after = name
    }
    let matching = objectNames.filter { $0.hasPrefix(prefix) && after.utf8.lexicographicallyPrecedes($0.utf8) }
    let page = Array(matching.prefix(maxKeys))
    let truncated = matching.count > page.count
    let encode = options.honorsEncodingType && query["encoding-type"] == "url"
    let ordered = options.listsInReverse ? page.reversed() : page
    let contents = ordered.map { name in
      let size = object(name)?.count ?? 0
      return "<Contents><Key>\(xmlEscape(encode ? Self.formEncode(name) : name))</Key><LastModified>2026-03-01T12:00:00.000Z</LastModified><Size>\(size)</Size></Contents>"
    }
    var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>\(options.bucket)</Name>"
    xml += "<Prefix>\(xmlEscape(encode ? Self.formEncode(prefix) : prefix))</Prefix><KeyCount>\(page.count)</KeyCount><MaxKeys>\(maxKeys)</MaxKeys>"
    if encode { xml += "<EncodingType>url</EncodingType>" }
    xml += "<IsTruncated>\(truncated)</IsTruncated>"
    if truncated, !options.truncatesWithoutToken, let last = page.last { xml += "<NextContinuationToken>tok-\(Data(last.utf8).base64EncodedString())</NextContinuationToken>" }
    xml += contents.joined() + "</ListBucketResult>"
    return try respond(url, status: 200, body: Data(xml.utf8))
  }

  private func get(_ url: URL, _ name: String) throws -> (Data, HTTPURLResponse) {
    guard let data = object(name) else { return try respond(url, status: 404, code: "NoSuchKey", message: "The specified key does not exist.") }
    return try respond(url, status: 200, body: data)
  }

  private func head(_ url: URL, _ name: String) throws -> (Data, HTTPURLResponse) {
    guard object(name) != nil, let modified = state.withLock({ $0.modified[name] }) else { return try respond(url, status: 404) }
    return try respond(url, status: 200, headers: ["Last-Modified": Self.httpDate(modified)])
  }

  private func put(_ url: URL, _ name: String, headers: [String: String], body: Data) throws -> (Data, HTTPURLResponse) {
    if let condition = headers["if-none-match"] {
      guard condition == "*" else { return try respond(url, status: 400, code: "InvalidArgument", message: "Only * is supported") }
      if options.refusesConditionalWritesAsUnimplemented {
        return try respond(url, status: 501, code: "NotImplemented", message: "A header you provided implies functionality that is not implemented")
      }
      let refused = state.withLock { state -> Bool in
        guard !(options.honorsConditionalWrites && state.objects[name] != nil) else { return true }
        state.objects[name] = body
        state.modified[name] = options.serverDate
        return false
      }
      if refused { return try respond(url, status: 412, code: "PreconditionFailed", message: "At least one of the pre-conditions you specified did not hold") }
      return try respond(url, status: 200)
    }
    state.withLock { state in
      state.objects[name] = body
      state.modified[name] = options.serverDate
    }
    return try respond(url, status: 200)
  }

  private func delete(_ url: URL, headers: [String: String], body: Data) throws -> (Data, HTTPURLResponse) {
    guard headers["content-md5"] == Data(Insecure.MD5.hash(data: body)).base64EncodedString() else {
      recordViolation("DeleteObjects without a matching Content-MD5")
      return try respond(url, status: 400, code: "InvalidDigest", message: "The Content-MD5 you specified was invalid.")
    }
    guard let root = S3XMLNode.parse(body), root.name == "Delete", root.value("Quiet") == "true" else {
      return try respond(url, status: 400, code: "MalformedXML", message: "The XML you provided was not well-formed")
    }
    let names = root.children("Object").compactMap { $0.value("Key") }
    guard (1...1000).contains(names.count) else { return try respond(url, status: 400, code: "MalformedXML", message: "\(names.count) keys") }
    let errors = state.withLock { state -> [(String, String)] in
      var errors: [(String, String)] = []
      for name in names {
        if let code = state.perKeyDeleteErrors[name] {
          errors.append((name, code))
        } else {
          state.objects[name] = nil
          state.modified[name] = nil
        }
      }
      return errors
    }
    let errorXML = errors.map { "<Error><Key>\(xmlEscape($0.0))</Key><Code>\($0.1)</Code><Message>Failed</Message></Error>" }.joined()
    let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><DeleteResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\(errorXML)</DeleteResult>"
    return try respond(url, status: 200, body: Data(xml.utf8))
  }

  private func respond(_ url: URL, status: Int, code: String? = nil, message: String? = nil, headers: [String: String] = [:], body: Data = Data()) throws -> (Data, HTTPURLResponse)
  {
    var fields = headers
    fields["Date"] = Self.httpDate(options.serverDate)
    var payload = body
    if let code {
      payload = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>\(code)</Code><Message>\(xmlEscape(message ?? ""))</Message><RequestId>FAKE</RequestId></Error>".utf8)
      fields["Content-Type"] = "application/xml"
    }
    guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields) else { throw URLError(.badServerResponse) }
    return (payload, response)
  }

  private func takeFault(for operation: Operation) -> Fault? {
    state.withLock { state in
      guard let index = state.faults.firstIndex(where: { $0.operation == nil || $0.operation == operation }) else { return nil }
      let fault = state.faults[index]
      guard fault.skip == 0 else {
        state.faults[index].skip -= 1
        return nil
      }
      state.faults[index].remaining -= 1
      if state.faults[index].remaining <= 0 { state.faults.remove(at: index) }
      return fault
    }
  }

  private func unroutable(_ detail: String) -> (operation: Operation, objectName: String?, query: [String: String])? {
    recordViolation(detail)
    return nil
  }

  private func recordViolation(_ detail: String) {
    state.withLock { $0.violations.append(detail) }
  }

  private func violation(_ code: String, _ detail: String) -> (code: String, message: String) {
    recordViolation(detail)
    return (code, detail)
  }

  private func xmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
  }

  /// CFNetwork sends the Host header lowercased, so a real service signs against the lowercased host.
  private static func receivedHost(_ url: URL) -> String {
    let host = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost ?? "").lowercased()
    return url.port.map { "\(host):\($0)" } ?? host
  }

  private static func parseAuthorization(_ value: String) -> (accessKeyID: String, scope: String, signedHeaders: [String], signature: String)? {
    let prefix = "AWS4-HMAC-SHA256 "
    guard value.hasPrefix(prefix) else { return nil }
    var fields: [String: String] = [:]
    for part in value.dropFirst(prefix.count).split(separator: ",") {
      let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
      guard pair.count == 2 else { return nil }
      fields[pair[0]] = pair[1]
    }
    guard let credential = fields["Credential"], let signed = fields["SignedHeaders"], let signature = fields["Signature"] else { return nil }
    guard signature.count == 64, signature.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
    let slash = credential.firstIndex(of: "/") ?? credential.endIndex
    return (String(credential[..<slash]), String(credential[slash...].dropFirst()), signed.split(separator: ";").map(String.init), signature)
  }

  private static func parseAmzDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    guard value.count == 16 else { return nil }
    return formatter.date(from: value)
  }

  static func httpDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.string(from: date)
  }

  private static func decodedQuery(_ query: String?) -> [String: String] {
    guard let query, !query.isEmpty else { return [:] }
    var items: [String: String] = [:]
    for pair in query.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
      items[percentDecoded(parts[0]) ?? parts[0]] = parts.count > 1 ? percentDecoded(parts[1]) ?? parts[1] : ""
    }
    return items
  }

  private static func percentDecoded(_ text: String) -> String? {
    text.removingPercentEncoding
  }

  private static func awsEncode(_ text: String) -> String {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
  }

  private static func formEncode(_ text: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~/ ")
    return (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text).replacingOccurrences(of: " ", with: "+")
  }

  private static func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}
