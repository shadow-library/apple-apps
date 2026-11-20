import Foundation
import ShadowNetworking

public actor InMemoryOAuthTokenStore: OAuthTokenStore {
  public private(set) var tokens: OAuthTokens?
  public private(set) var saved: [OAuthTokens] = []
  public private(set) var loadCount = 0
  public private(set) var clearCount = 0
  private var saveFailures: [OAuthError] = []
  private var holdingSaves = false
  private var heldSaves: [CheckedContinuation<Void, Never>] = []

  public init(tokens: OAuthTokens? = nil) {
    self.tokens = tokens
  }

  public func load() throws(OAuthError) -> OAuthTokens? {
    loadCount += 1
    return tokens
  }

  public var heldSaveCount: Int { heldSaves.count }

  public func save(_ tokens: OAuthTokens) async throws(OAuthError) {
    if holdingSaves { await withCheckedContinuation { heldSaves.append($0) } }
    if !saveFailures.isEmpty { throw saveFailures.removeFirst() }
    self.tokens = tokens
    saved.append(tokens)
  }

  public func clear() throws(OAuthError) {
    clearCount += 1
    tokens = nil
  }

  public func holdSaves() {
    holdingSaves = true
  }

  public func releaseSaves() {
    holdingSaves = false
    let held = heldSaves
    heldSaves = []
    for save in held { save.resume() }
  }

  public func failNextSave(with error: OAuthError) {
    saveFailures.append(error)
  }

  public func replace(with tokens: OAuthTokens?) {
    self.tokens = tokens
  }
}
