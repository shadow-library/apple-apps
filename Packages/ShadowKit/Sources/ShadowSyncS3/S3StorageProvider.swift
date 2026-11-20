import CryptoKit
import Foundation
import ShadowCore
import ShadowNetworking
import ShadowSync

/// Without conditional writes, `.ifAbsent` checks with HEAD before PUT, so two writers racing on one key can both succeed and the later one wins.
public struct S3StorageProvider: StorageProvider {
  /// Above every object the sync codecs produce (a 64 MiB segment, a 32 MiB base part) and far below S3's 5 GiB single PUT; a put is held in memory whole.
  public static let maxObjectBytes = 256 * 1024 * 1024
  static let maxKeysPerList = 1000
  static let maxKeysPerDelete = 1000

  public let configuration: S3Configuration
  public let capabilities: StorageCapabilities
  private let credentials: S3Credentials
  private let transport: any HTTPTransport
  private let now: @Sendable () -> Date
  private let signer: S3Signer

  public init(
    configuration: S3Configuration,
    credentials: S3Credentials,
    transport: any HTTPTransport = URLSessionTransport(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configuration = configuration
    self.credentials = credentials
    self.transport = transport
    self.now = now
    signer = S3Signer(credentials: credentials, region: configuration.region)
    capabilities = StorageCapabilities(
      pushesChangeNotices: false,
      supportsPutIfAbsent: configuration.supportsConditionalWrites,
      hasChangeFeed: false,
      reportsServerTime: true,
      maxObjectBytes: Self.maxObjectBytes,
      classPolicy: .unrestricted
    )
  }

  public func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    let namePrefix = configuration.keyPrefix.isEmpty ? "" : configuration.keyPrefix + "/"
    var query: [(name: String, value: String)] = [("list-type", "2"), ("prefix", namePrefix + prefix), ("max-keys", String(Self.maxKeysPerList)), ("encoding-type", "url")]
    if let cursor { query.append(try S3ListCursor(cursor).queryItem) }
    let response = try await send("GET", object: nil, query: query)
    try response.requireSuccess(key: nil, context: failureContext)
    return try S3Listing(xml: response.body).page(namePrefix: namePrefix, prefix: prefix)
  }

  public func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    let response = try await send("GET", object: key)
    try response.requireSuccess(key: key, context: failureContext)
    let declared = response.headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
    guard max(declared, response.body.count) <= Self.maxObjectBytes else { throw .tooLarge(key, limit: Self.maxObjectBytes) }
    return response.body
  }

  public func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    guard data.count <= Self.maxObjectBytes else { throw .tooLarge(key, limit: Self.maxObjectBytes) }
    let atomic = condition == .ifAbsent && configuration.supportsConditionalWrites
    if condition == .ifAbsent && !atomic, try await exists(key) { throw .alreadyExists(key) }
    let response = try await putObject(key, data: data, ifNoneMatch: atomic)
    try response.requireSuccess(key: key, context: failureContext)
    return PutReceipt(serverTime: response.serverDate)
  }

  public func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    var seen: Set<ObjectKey> = []
    let unique = keys.filter { seen.insert($0).inserted }
    for start in stride(from: 0, to: unique.count, by: Self.maxKeysPerDelete) {
      try await deleteBatch(unique[start..<min(start + Self.maxKeysPerDelete, unique.count)])
    }
  }

  public func changeNotices() -> AsyncStream<Void> {
    AsyncStream { _ in }
  }

  func putObject(_ key: ObjectKey, data: Data, ifNoneMatch: Bool) async throws(StorageError) -> S3Response {
    var headers = ["content-type": "application/octet-stream"]
    if ifNoneMatch { headers["if-none-match"] = "*" }
    return try await send("PUT", object: key, headers: headers, body: data)
  }

  var failureContext: S3FailureContext {
    S3FailureContext(bucket: configuration.bucket, maxObjectBytes: Self.maxObjectBytes, now: now(), credentials: credentials)
  }

  private func exists(_ key: ObjectKey) async throws(StorageError) -> Bool {
    let response = try await send("HEAD", object: key)
    if response.status == 404 { return false }
    try response.requireSuccess(key: key, context: failureContext)
    return true
  }

  private func deleteBatch(_ keys: ArraySlice<ObjectKey>) async throws(StorageError) {
    guard !keys.isEmpty else { return }
    let objects = keys.map { "<Object><Key>\(S3XMLNode.escape(configuration.objectName(for: $0)))</Key></Object>" }.joined()
    let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Delete xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Quiet>true</Quiet>\(objects)</Delete>"
    let body = Data(xml.utf8)
    let headers = ["content-type": "application/xml", "content-md5": Data(Insecure.MD5.hash(data: body)).base64EncodedString()]
    let response = try await send("POST", object: nil, query: [("delete", "")], headers: headers, body: body)
    try response.requireSuccess(key: nil, context: failureContext)
    guard !response.body.isEmpty else { return }
    guard let result = S3XMLNode.parse(response.body), result.name == "DeleteResult" else {
      throw .unavailable("The storage service returned a delete result that could not be read.")
    }
    for error in result.children("Error") where error.value("Code") != "NoSuchKey" {
      let failure = S3Failure(status: 200, code: error.value("Code"), message: error.value("Message"))
      throw failure.storageError(key: error.value("Key").flatMap(objectKey(forName:)), context: failureContext)
    }
  }

  private func objectKey(forName name: String) -> ObjectKey? {
    guard !configuration.keyPrefix.isEmpty else { return ObjectKey(name) }
    let namePrefix = configuration.keyPrefix + "/"
    guard name.utf8.starts(with: namePrefix.utf8) else { return nil }
    return ObjectKey(String(decoding: name.utf8.dropFirst(namePrefix.utf8.count), as: UTF8.self))
  }

  func send(
    _ method: String,
    object key: ObjectKey?,
    query: [(name: String, value: String)] = [],
    headers: [String: String] = [:],
    body: Data = Data()
  ) async throws(StorageError) -> S3Response {
    let carriesBody = method == "PUT" || method == "POST"
    let signable = S3SignableRequest(
      method: method, host: host, path: path(for: key), query: query, headers: headers, payloadHash: S3Signer.hexSHA256(carriesBody ? body : Data()))
    let urlText = "\(configuration.endpoint.scheme ?? "https")://\(host)\(signable.canonicalURI)\(Self.urlQuery(query))"
    guard let url = URL(string: urlText) else { throw .underlying("The request address could not be built.") }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
    request.httpMethod = method
    if carriesBody {
      request.httpBody = body
      request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    }
    for (name, value) in signer.authorizedHeaders(for: signable, at: now()) { request.setValue(value, forHTTPHeaderField: name) }
    do {
      let (data, response) = try await transport.send(request)
      return S3Response(status: response.statusCode, headers: response.lowercasedHeaderFields, body: data)
    } catch {
      throw S3Failure.transport(error)
    }
  }

  private var host: String {
    let components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)
    let name = components?.encodedHost ?? ""
    let defaultPort = configuration.endpoint.scheme == "http" ? 80 : 443
    let authority = components?.port.flatMap { $0 == defaultPort ? nil : "\(name):\($0)" } ?? name
    return configuration.addressingStyle == .virtualHosted ? "\(configuration.bucket).\(authority)" : authority
  }

  private func path(for key: ObjectKey?) -> String {
    let name = key.map(configuration.objectName(for:))
    switch configuration.addressingStyle {
    case .virtualHosted: return "/" + (name ?? "")
    case .path: return "/" + configuration.bucket + (name.map { "/" + $0 } ?? "")
    }
  }

  private static func urlQuery(_ query: [(name: String, value: String)]) -> String {
    guard !query.isEmpty else { return "" }
    let items = query.map { item in
      let name = S3URIEncoding.encode(item.name, keepingSlashes: false)
      return item.value.isEmpty ? name : "\(name)=\(S3URIEncoding.encode(item.value, keepingSlashes: false))"
    }
    return "?" + items.joined(separator: "&")
  }
}

struct S3Response: Sendable {
  let status: Int
  let headers: [String: String]
  let body: Data

  var isSuccess: Bool { (200..<300).contains(status) }

  var serverDate: Date? {
    headers["date"].flatMap(TrustedClock.parseHTTPDate)
  }

  func requireSuccess(key: ObjectKey?, context: S3FailureContext) throws(StorageError) {
    guard !isSuccess else { return }
    throw S3Failure(status: status, headers: headers, body: body).storageError(key: key, context: context)
  }
}
