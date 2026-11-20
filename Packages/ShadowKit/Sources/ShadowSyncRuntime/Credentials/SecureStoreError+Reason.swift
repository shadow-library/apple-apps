import Foundation
import ShadowKeychain

extension SecureStoreError {
  var reason: String {
    guard case .unexpectedStatus(let status) = self else { return code }
    return "\(code) \(status)"
  }
}
