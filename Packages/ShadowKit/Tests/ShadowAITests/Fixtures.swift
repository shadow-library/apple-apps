import Foundation
import Synchronization
import Testing

@testable import ShadowAI

func makeCredential(_ origin: String = "https://api.anthropic.com", secret: String = "sk") throws -> ProviderCredential {
  let url = try #require(URL(string: origin))
  return try #require(ProviderCredential(origin: url, secret: secret))
}

final class RunCounter: Sendable {
  private let count = Mutex(0)

  var value: Int { count.withLock { $0 } }

  func increment() {
    count.withLock { $0 += 1 }
  }
}
