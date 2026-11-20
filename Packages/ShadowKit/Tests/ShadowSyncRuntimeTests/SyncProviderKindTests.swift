import Foundation
import ShadowSyncRuntime
import Testing

@Suite("SyncProviderKind", TestTimeLimit.quick)
struct SyncProviderKindTests {
  @Test("should encode each kind as its stable name and round-trip")
  func roundTrips() throws {
    let encoded = try JSONEncoder().encode(SyncProviderKind.allCases)

    #expect(String(decoding: encoded, as: UTF8.self) == #"["iCloud","localFolder","s3","oneDrive","googleDrive"]"#)
    #expect(try JSONDecoder().decode([SyncProviderKind].self, from: encoded) == SyncProviderKind.allCases)
  }

  @Test("should refuse a kind it does not know")
  func refusesUnknown() {
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(SyncProviderKind.self, from: Data(#""dropbox""#.utf8)) }
  }
}
