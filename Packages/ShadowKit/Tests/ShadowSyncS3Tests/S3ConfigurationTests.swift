import Foundation
import ShadowSync
import ShadowSyncS3
import Testing

@Suite("S3Configuration", TestTimeLimit.quick)
struct S3ConfigurationTests {
  private static func make(
    endpoint: String = "https://s3.eu-west-1.amazonaws.com",
    region: String = "eu-west-1",
    bucket: String = "shadow-vaults",
    keyPrefix: String = "",
    style: S3Configuration.AddressingStyle = .virtualHosted,
    insecureLocalhost: Bool = false
  ) throws -> S3Configuration {
    try S3Configuration(
      endpoint: #require(URL(string: endpoint)),
      region: region,
      bucket: bucket,
      keyPrefix: keyPrefix,
      addressingStyle: style,
      allowsInsecureLocalhost: insecureLocalhost
    )
  }

  private static func failure(_ build: () throws -> S3Configuration) -> S3ConfigurationError? {
    do {
      _ = try build()
      return nil
    } catch let error as S3ConfigurationError {
      return error
    } catch {
      return nil
    }
  }

  @Test("should default to virtual-hosted addressing without conditional writes and drop a trailing slash from the endpoint")
  func appliesDefaults() throws {
    let configuration = try S3Configuration(endpoint: #require(URL(string: "HTTPS://s3.eu-west-1.amazonaws.com/")), region: "eu-west-1", bucket: "shadow-vaults")

    #expect(configuration.addressingStyle == .virtualHosted)
    #expect(configuration.supportsConditionalWrites == false)
    #expect(configuration.allowsInsecureLocalhost == false)
    #expect(configuration.keyPrefix.isEmpty)
    #expect(configuration.endpoint.absoluteString == "https://s3.eu-west-1.amazonaws.com")
  }

  @Test("should lowercase the endpoint host, since the Host header goes out lowercased and is signed")
  func lowercasesHost() throws {
    #expect(try Self.make(endpoint: "https://S3.EU-West-1.AmazonAWS.com:9443").endpoint.absoluteString == "https://s3.eu-west-1.amazonaws.com:9443")
    #expect(try Self.make(endpoint: "http://LocalHost:9000", style: .path, insecureLocalhost: true).endpoint.absoluteString == "http://localhost:9000")
    #expect(try Self.make(endpoint: "https://Bücher.Example").endpoint.absoluteString == "https://xn--bcher-kva.example")
  }

  @Test("should refuse plain http unless a loopback endpoint opts in")
  func guardsPlainHTTP() throws {
    #expect(Self.failure { try Self.make(endpoint: "http://s3.example.com") } == .insecureEndpoint)
    #expect(Self.failure { try Self.make(endpoint: "http://127.0.0.1:9000", style: .path) } == .insecureEndpoint)
    #expect(Self.failure { try Self.make(endpoint: "http://minio.local:9000", style: .path, insecureLocalhost: true) } == .insecureEndpoint)

    let local = try Self.make(endpoint: "http://localhost:9000", style: .path, insecureLocalhost: true)
    #expect(local.endpoint.absoluteString == "http://localhost:9000")
    _ = try Self.make(endpoint: "http://[::1]:9000", style: .path, insecureLocalhost: true)
  }

  @Test(
    "should refuse endpoints with another scheme, a path, a query, a fragment or credentials",
    arguments: ["ftp://s3.example.com", "https://s3.example.com/bucket", "https://s3.example.com?x=1", "https://s3.example.com#f", "https://u:p@s3.example.com", "s3.example.com"]
  )
  func refusesEndpoints(endpoint: String) {
    guard case .invalidEndpoint = Self.failure({ try Self.make(endpoint: endpoint) }) else {
      Issue.record("Expected an invalid endpoint for \(endpoint)")
      return
    }
  }

  @Test("should need path-style addressing for an IP address or localhost")
  func needsPathStyleForAddresses() throws {
    guard case .invalidEndpoint = Self.failure({ try Self.make(endpoint: "https://10.0.0.5:9000") }) else {
      Issue.record("Expected virtual-hosted addressing on an IP address to be refused")
      return
    }
    _ = try Self.make(endpoint: "https://10.0.0.5:9000", style: .path)
  }

  @Test("should accept S3 bucket names", arguments: ["abc", "shadow-vaults", "vaults.2026", "a1-b2", String(repeating: "b", count: 63)])
  func acceptsBuckets(bucket: String) throws {
    #expect(try Self.make(bucket: bucket, style: .path).bucket == bucket)
  }

  @Test(
    "should refuse bucket names outside the S3 rules",
    arguments: ["ab", String(repeating: "b", count: 64), "Shadow", "shadow_vaults", "-shadow", "shadow-", "sha..dow", "192.168.1.10", "shadow vaults"]
  )
  func refusesBuckets(bucket: String) {
    #expect(Self.failure { try Self.make(bucket: bucket, style: .path) } == .invalidBucket)
  }

  @Test("should need path-style addressing for a bucket name with dots")
  func needsPathStyleForDottedBuckets() {
    #expect(Self.failure { try Self.make(bucket: "vaults.2026") } == .dottedBucketNeedsPathStyle)
  }

  @Test("should accept regions such as auto and refuse malformed ones")
  func validatesRegions() throws {
    for region in ["us-east-1", "auto", "us-west-004", "garage_1"] { _ = try Self.make(region: region) }
    for region in ["", "US-EAST-1", "eu west", String(repeating: "r", count: 65)] { #expect(Self.failure { try Self.make(region: region) } == .invalidRegion) }
  }

  @Test("should compose object names under the key prefix")
  func composesObjectNames() throws {
    let key = try #require(ObjectKey("replicas/abc/segment-1"))

    #expect(try Self.make().objectName(for: key) == "replicas/abc/segment-1")
    #expect(try Self.make(keyPrefix: "users/ada/vault").objectName(for: key) == "users/ada/vault/replicas/abc/segment-1")
  }

  @Test(
    "should refuse key prefixes that would not compose into valid object names",
    arguments: ["/vault", "vault/", "a//b", "va ult", "..", "a/./b", String(repeating: "p", count: 512)]
  )
  func refusesKeyPrefixes(prefix: String) {
    #expect(Self.failure { try Self.make(keyPrefix: prefix) } == .invalidKeyPrefix)
  }

  @Test("should keep the longest prefix whose composed names stay within the S3 key limit")
  func boundsKeyPrefix() throws {
    let prefix = String(repeating: "p", count: S3Configuration.maxKeyPrefixUTF8Length)
    let key = try #require(ObjectKey(String(repeating: "k", count: ObjectKey.maxUTF8Length)))

    #expect(try Self.make(keyPrefix: prefix).objectName(for: key).utf8.count == S3Configuration.maxKeyUTF8Length)
  }
}

@Suite("S3Credentials", TestTimeLimit.quick)
struct S3CredentialsTests {
  @Test("should never show the secret key or session token")
  func redactsSecrets() throws {
    let credentials = try S3Credentials(accessKeyID: "AKIAEXAMPLE", secretAccessKey: "wJalr/XUtnFEMI+K7MDENG", sessionToken: "FwoGZXIvYXdzEBYaD")
    var dumped = ""
    dump(credentials, to: &dumped)

    for text in [String(describing: credentials), String(reflecting: credentials), dumped] {
      #expect(text.contains("AKIAEXAMPLE"))
      #expect(!text.contains("wJalr/XUtnFEMI+K7MDENG"))
      #expect(!text.contains("FwoGZXIvYXdzEBYaD"))
    }
  }

  @Test("should refuse empty or whitespace-bearing keys and tokens")
  func refusesMalformedCredentials() {
    #expect(throws: S3ConfigurationError.self) { try S3Credentials(accessKeyID: "", secretAccessKey: "secret") }
    #expect(throws: S3ConfigurationError.self) { try S3Credentials(accessKeyID: "AKIA", secretAccessKey: "sec ret") }
    #expect(throws: S3ConfigurationError.self) { try S3Credentials(accessKeyID: "AKIA", secretAccessKey: "secret", sessionToken: "") }
  }
}
