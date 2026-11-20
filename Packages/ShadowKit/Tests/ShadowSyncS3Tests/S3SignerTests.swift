import Foundation
import Testing

@testable import ShadowSyncS3

@Suite("S3Signer", TestTimeLimit.quick)
struct S3SignerTests {
  private static let host = "examplebucket.s3.amazonaws.com"
  private static let instant = Date(timeIntervalSince1970: 1_369_353_600)
  private static let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  private static func signer(sessionToken: String? = nil) throws -> S3Signer {
    try S3Signer(
      credentials: S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", sessionToken: sessionToken),
      region: "us-east-1"
    )
  }

  private static func request(
    _ method: String,
    _ path: String,
    query: [(name: String, value: String)] = [],
    headers: [String: String] = [:],
    payloadHash: String = emptyHash
  ) -> S3SignableRequest {
    var signed = headers
    signed["x-amz-date"] = "20130524T000000Z"
    signed["x-amz-content-sha256"] = payloadHash
    return S3SignableRequest(method: method, host: host, path: path, query: query, headers: signed, payloadHash: payloadHash)
  }

  @Test("should reproduce the AWS GetObject example with a Range header")
  func signsGetObjectExample() throws {
    let request = Self.request("GET", "/test.txt", headers: ["Range": "bytes=0-9"])
    let canonical = """
      GET
      /test.txt

      host:examplebucket.s3.amazonaws.com
      range:bytes=0-9
      x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
      x-amz-date:20130524T000000Z

      host;range;x-amz-content-sha256;x-amz-date
      e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
      """
    let signer = try Self.signer()

    #expect(signer.canonicalRequest(request) == canonical)
    #expect(
      signer.stringToSign(request, at: S3Timestamp(Self.instant))
        == "AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\n7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972")
    #expect(signer.signature(request, at: S3Timestamp(Self.instant)) == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
  }

  @Test("should reproduce the AWS PutObject example with an encoded key and extra signed headers")
  func signsPutObjectExample() throws {
    let payloadHash = S3Signer.hexSHA256(Data("Welcome to Amazon S3.".utf8))
    let request = Self.request(
      "PUT", "/test$file.text", headers: ["Date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class": "REDUCED_REDUNDANCY"], payloadHash: payloadHash)
    let signer = try Self.signer()

    #expect(payloadHash == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
    #expect(signer.canonicalRequest(request).hasPrefix("PUT\n/test%24file.text\n\ndate:Fri, 24 May 2013 00:00:00 GMT\n"))
    #expect(signer.stringToSign(request, at: S3Timestamp(Self.instant)).hasSuffix("9e0e90d9c76de8fa5b200d8c849cd5b8dc7a3be3951ddb7f6a76b4158342019d"))
    #expect(signer.signature(request, at: S3Timestamp(Self.instant)) == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
  }

  @Test("should reproduce the AWS GetBucketLifecycle example with a valueless query parameter")
  func signsLifecycleExample() throws {
    let request = Self.request("GET", "/", query: [("lifecycle", "")])

    #expect(try Self.signer().canonicalRequest(request).hasPrefix("GET\n/\nlifecycle=\n"))
    #expect(try Self.signer().signature(request, at: S3Timestamp(Self.instant)) == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
  }

  @Test("should reproduce the AWS ListObjects example with sorted query parameters")
  func signsListExample() throws {
    let request = Self.request("GET", "/", query: [("prefix", "J"), ("max-keys", "2")])

    #expect(request.canonicalQuery == "max-keys=2&prefix=J")
    #expect(try Self.signer().signature(request, at: S3Timestamp(Self.instant)) == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
  }

  @Test("should build the Authorization header and sign the session token")
  func authorizesWithSessionToken() throws {
    let request = S3SignableRequest(method: "GET", host: Self.host, path: "/test.txt", query: [], headers: [:], payloadHash: Self.emptyHash)
    let headers = try Self.signer(sessionToken: "FQoGZXIvYXdzEXAMPLE").authorizedHeaders(for: request, at: Self.instant)
    let authorization = try #require(headers["Authorization"])

    #expect(headers["x-amz-date"] == "20130524T000000Z")
    #expect(headers["x-amz-content-sha256"] == Self.emptyHash)
    #expect(headers["x-amz-security-token"] == "FQoGZXIvYXdzEXAMPLE")
    #expect(authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"))
    #expect(authorization.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token,Signature="))
    #expect(!authorization.contains("wJalrXUtnFEMI"))
  }

  @Test("should sign the GetObject example identically through the Authorization header")
  func authorizesGetObjectExample() throws {
    let request = S3SignableRequest(method: "GET", host: Self.host, path: "/test.txt", query: [], headers: ["Range": "bytes=0-9"], payloadHash: Self.emptyHash)
    let authorization = try Self.signer().authorizedHeaders(for: request, at: Self.instant)["Authorization"]

    #expect(
      authorization
        == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,"
        + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
  }

  @Test("should encode path segments once and keep slashes, tildes and unreserved bytes")
  func encodesPaths() {
    #expect(S3SignableRequest(method: "GET", host: "h", path: "/a b/c~d/e+f/g%h/ü", query: [], headers: [:], payloadHash: "").canonicalURI == "/a%20b/c~d/e%2Bf/g%25h/%C3%BC")
    #expect(S3SignableRequest(method: "GET", host: "h", path: "", query: [], headers: [:], payloadHash: "").canonicalURI == "/")
    #expect(S3SignableRequest(method: "GET", host: "h", path: "/bucket/a//b/", query: [], headers: [:], payloadHash: "").canonicalURI == "/bucket/a//b/")
  }

  @Test("should encode slashes, plus, equals and spaces in query values and sort by encoded name then value")
  func encodesQueries() {
    let request = S3SignableRequest(
      method: "GET", host: "h", path: "/",
      query: [("prefix", "vault/a b+c=d~"), ("continuation-token", "1/x+y=="), ("delete", ""), ("a", "2"), ("a", "10")], headers: [:], payloadHash: "")

    #expect(request.canonicalQuery == "a=10&a=2&continuation-token=1%2Fx%2By%3D%3D&delete=&prefix=vault%2Fa%20b%2Bc%3Dd~")
  }

  @Test("should trim header values, collapse inner spaces and lowercase header names")
  func canonicalizesHeaders() throws {
    let request = Self.request("GET", "/k", headers: ["X-Amz-Meta-Note": "  two   spaces  here "])

    #expect(try Self.signer().canonicalRequest(request).contains("\nx-amz-meta-note:two spaces here\n"))
  }

  @Test("should decode percent escapes, read plus as space only when asked and refuse broken escapes")
  func decodesListingNames() {
    #expect(S3URIEncoding.decode("a%2Fb+c%2Bd", plusAsSpace: true) == "a/b c+d")
    #expect(S3URIEncoding.decode("a+b", plusAsSpace: false) == "a+b")
    #expect(S3URIEncoding.decode("%C3%BC%01", plusAsSpace: true) == "ü\u{01}")
    #expect(S3URIEncoding.decode("bad%2", plusAsSpace: true) == nil)
    #expect(S3URIEncoding.decode("bad%zz", plusAsSpace: true) == nil)
    #expect(S3URIEncoding.decode("%FF", plusAsSpace: true) == nil)
  }

  @Test("should format the signing time in UTC whatever the time zone")
  func formatsTimestamps() {
    let stamp = S3Timestamp(Date(timeIntervalSince1970: 1_772_409_599))

    #expect(stamp.date == "20260301")
    #expect(stamp.dateTime == "20260301T235959Z")
  }
}
