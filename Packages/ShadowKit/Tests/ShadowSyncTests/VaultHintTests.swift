import Foundation
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("VaultHint")
struct VaultHintTests {
  private static func error(_ text: String) -> ReplicaFileError? {
    error(Data(text.utf8))
  }

  private static func error(_ data: Data) -> ReplicaFileError? {
    do {
      _ = try VaultHint(decoding: data)
      return nil
    } catch {
      return error
    }
  }

  @Test("should round trip and pin the canonical bytes")
  func shouldRoundTrip() throws {
    let hint = VaultHint(vault: try CodecFixtures.vault("vault-one"))
    #expect(String(decoding: hint.encoded(), as: UTF8.self) == #"{"format":1,"vault":"vault-one"}"#)
    #expect(try VaultHint(decoding: hint.encoded()) == hint)
    #expect(hint.format == VaultHint.currentFormat)
  }

  @Test("should accept non canonical but valid input")
  func shouldAcceptNonCanonical() throws {
    let hint = try VaultHint(decoding: Data("{ \"vault\" : \"vault-one\" ,\n \"format\" : 1 }\n".utf8))
    #expect(hint.vault == (try CodecFixtures.vault("vault-one")))
  }

  @Test("should accept a hint of exactly the maximum size")
  func shouldAcceptMaximumSize() throws {
    let body = Data(#"{"format":1,"vault":"v"}"#.utf8)
    let padded = body + Data(repeating: 0x20, count: VaultHint.maximumBytes - body.count)
    #expect(try VaultHint(decoding: padded).vault.rawValue == "v")
    #expect(Self.error(padded + Data([0x20])) == .tooLarge)
  }

  @Test("should report a newer format before looking at anything else")
  func shouldReportUnsupportedFormat() {
    #expect(Self.error(#"{"format":2,"vault":"vault-one","future":[1,2]}"#) == .unsupportedFormat(2))
    #expect(Self.error(#"{"format":9}"#) == .unsupportedFormat(9))
    #expect(Self.error(#"{"format":2,"vault":"Not Valid"}"#) == .unsupportedFormat(2))
  }

  @Test(
    "should reject malformed hints",
    arguments: [
      "not json",
      "[]",
      "{}",
      #"{"format":1}"#,
      #"{"vault":"vault-one"}"#,
      #"{"format":1,"vault":"vault-one","extra":1}"#,
      #"{"format":1,"vault":"Not_Valid"}"#,
      #"{"format":1,"vault":""}"#,
      #"{"format":1,"vault":5}"#,
      #"{"format":0,"vault":"vault-one"}"#,
      #"{"format":-1,"vault":"vault-one"}"#,
      #"{"format":"1","vault":"vault-one"}"#,
      #"{"format":1.0,"vault":"vault-one"}"#,
      #"{"format":null,"vault":"vault-one"}"#,
      #"{"format":1,"format":1,"vault":"vault-one"}"#,
    ])
  func shouldRejectMalformed(text: String) {
    guard case .malformed? = Self.error(text) else {
      Issue.record("expected malformed for \(text), got \(String(describing: Self.error(text)))")
      return
    }
  }

  @Test("should reject an oversize hint")
  func shouldRejectOversize() {
    #expect(Self.error(Data(repeating: 0x20, count: VaultHint.maximumBytes + 1)) == .tooLarge)
  }

  @Test("should never trap on random bytes")
  func shouldSurviveRandomBytes() throws {
    try forAll(iterations: 300) { generator in
      _ = Self.error(generator.data(count: generator.int(in: 0...200)))
    }
  }
}
