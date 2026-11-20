import Foundation

public actor OAuthSession {
  public static let defaultRefreshMargin = Duration.seconds(120)

  private typealias Outcome = Result<OAuthTokens, OAuthError>

  public nonisolated let client: OAuthClient
  private let store: any OAuthTokenStore
  private let refreshMargin: Duration
  private var current: OAuthTokens?
  private var loaded = false
  private var unsaved = false
  private var epoch = 0
  private var deadRefreshToken: String?
  private var exhaustedAccessToken: String?
  private var refreshing: (id: Int, task: Task<Outcome, Never>)?
  private var refreshCount = 0
  private var storeQueue: Task<Void, Never>?
  private var saving: (tokens: OAuthTokens, task: Task<Result<Void, OAuthError>, Never>)?

  public init(client: OAuthClient, store: any OAuthTokenStore, refreshMargin: Duration = OAuthSession.defaultRefreshMargin) {
    self.client = client
    self.store = store
    self.refreshMargin = refreshMargin
  }

  public func signIn(with tokens: OAuthTokens) async throws(OAuthError) {
    reset(to: tokens)
    unsaved = true
    try await persistCurrent()
  }

  public func signOut() async throws(OAuthError) {
    reset(to: nil)
    try await serialized { store throws(OAuthError) in try await store.clear() }
  }

  public func accessToken() async throws(OAuthError) -> OAuthAccessToken {
    while true {
      let started = epoch
      var tokens = try await loadedTokens()
      if tokens.refreshDue(at: client.now(), margin: refreshMargin) {
        do throws(OAuthError) {
          tokens = try await refreshed(from: tokens)
        } catch {
          guard error.isRetryable, let expiresAt = tokens.expiresAt, client.now() < expiresAt else { throw error }
          try await persistCurrent()
        }
      } else if unsaved {
        try await persistCurrent()
      }
      if epoch == started { return tokens.accessCredential }
    }
  }

  public func refreshAfterRejection(of rejected: OAuthAccessToken) async throws(OAuthError) -> OAuthAccessToken {
    let tokens = try await loadedTokens()
    guard tokens.accessToken == rejected.value else { return try await accessToken() }
    guard exhaustedAccessToken != rejected.value else { throw .reauthorizationRequired }
    let refreshed = try await refreshed(from: tokens)
    guard refreshed.accessToken != rejected.value else {
      exhaustedAccessToken = rejected.value
      throw .reauthorizationRequired
    }
    return refreshed.accessCredential
  }

  private func reset(to tokens: OAuthTokens?) {
    epoch += 1
    current = tokens
    loaded = true
    unsaved = false
    refreshing = nil
    deadRefreshToken = nil
    exhaustedAccessToken = nil
  }

  private func loadedTokens() async throws(OAuthError) -> OAuthTokens {
    if !loaded {
      let stored = try await serialized { store throws(OAuthError) in try await store.load() }
      if !loaded {
        current = stored
        loaded = true
      }
    }
    guard let current else { throw .notSignedIn }
    return current
  }

  private func refreshed(from tokens: OAuthTokens) async throws(OAuthError) -> OAuthTokens {
    if let refreshing { return try await refreshing.task.value.get() }
    refreshCount += 1
    let id = refreshCount
    let task = Task { await self.runRefresh(from: tokens, id: id) }
    refreshing = (id, task)
    return try await task.value.get()
  }

  private func runRefresh(from tokens: OAuthTokens, id: Int) async -> Outcome {
    let started = epoch
    let outcome = await attemptRefresh(from: tokens, epoch: started)
    if refreshing?.id == id { refreshing = nil }
    guard epoch == started else { return current.map(Outcome.success) ?? .failure(.notSignedIn) }
    return outcome
  }

  private func attemptRefresh(from tokens: OAuthTokens, epoch started: Int) async -> Outcome {
    if let refreshToken = tokens.refreshToken, refreshToken != deadRefreshToken {
      let outcome = await refreshAndPersist(tokens, epoch: started)
      guard case .failure(.reauthorizationRequired) = outcome, epoch == started else { return outcome }
      deadRefreshToken = refreshToken
    }
    let stored: OAuthTokens?
    do throws(OAuthError) {
      stored = try await serialized { store throws(OAuthError) in try await store.load() }
    } catch {
      return .failure(error)
    }
    guard epoch == started else { return .failure(.notSignedIn) }
    guard let stored, stored != tokens, stored.refreshToken != deadRefreshToken || stored.accessToken != tokens.accessToken else {
      return .failure(.reauthorizationRequired)
    }
    current = stored
    unsaved = false
    guard stored.refreshDue(at: client.now(), margin: refreshMargin) else { return .success(stored) }
    guard stored.refreshToken != nil, stored.refreshToken != deadRefreshToken else { return .failure(.reauthorizationRequired) }
    let outcome = await refreshAndPersist(stored, epoch: started)
    if case .failure(.reauthorizationRequired) = outcome, epoch == started { deadRefreshToken = stored.refreshToken }
    return outcome
  }

  private func refreshAndPersist(_ tokens: OAuthTokens, epoch started: Int) async -> Outcome {
    do throws(OAuthError) {
      let refreshed = try await client.refresh(tokens)
      guard epoch == started else { return .failure(.notSignedIn) }
      current = refreshed
      unsaved = true
      try await persistCurrent()
      return .success(refreshed)
    } catch {
      return .failure(error)
    }
  }

  private func persistCurrent() async throws(OAuthError) {
    guard unsaved, let tokens = current else { return }
    let task: Task<Result<Void, OAuthError>, Never>
    if let saving, saving.tokens == tokens {
      task = saving.task
    } else {
      task = enqueue { store throws(OAuthError) in try await store.save(tokens) }
      saving = (tokens, task)
    }
    let result = await task.value
    if saving?.task == task { saving = nil }
    try result.get()
    if current == tokens { unsaved = false }
  }

  private func serialized<Value: Sendable>(_ operation: @escaping @Sendable (any OAuthTokenStore) async throws(OAuthError) -> Value) async throws(OAuthError) -> Value {
    try await enqueue(operation).value.get()
  }

  private func enqueue<Value: Sendable>(_ operation: @escaping @Sendable (any OAuthTokenStore) async throws(OAuthError) -> Value) -> Task<Result<Value, OAuthError>, Never> {
    let previous = storeQueue
    let store = store
    let task = Task<Result<Value, OAuthError>, Never> {
      await previous?.value
      do throws(OAuthError) {
        return .success(try await operation(store))
      } catch {
        return .failure(error)
      }
    }
    storeQueue = Task { _ = await task.value }
    return task
  }
}
