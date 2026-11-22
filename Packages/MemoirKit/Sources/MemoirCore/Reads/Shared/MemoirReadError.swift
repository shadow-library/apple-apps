import ShadowCore
import ShadowStore

public enum MemoirReadError: ShadowError {
  case store(StoreError)
  case finance(FinanceError)
  case invalidPage(offset: Int, limit: Int)

  public var code: String {
    switch self {
    case .store(let error): error.code
    case .finance(let error): error.code
    case .invalidPage: "memoir_read.invalid_page"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .store(let error): error.errorDescription
    case .finance(let error): error.errorDescription
    case .invalidPage(let offset, let limit): "A page starts at zero or later and holds at least one item, not \(limit) from \(offset)."
    }
  }

  init(_ error: StoreError) {
    switch error {
    case .aborted(let inner as MemoirReadError): self = inner
    case .aborted(let inner as FinanceError): self = .finance(inner)
    default: self = .store(error)
    }
  }
}

func readCall<T>(_ body: () async throws(StoreError) -> T) async throws(MemoirReadError) -> T {
  do {
    return try await body()
  } catch {
    throw MemoirReadError(error)
  }
}

/// A slice of an ordered list: the items from `offset`, at most `limit` of them, and how many matched in all.
public struct PageRequest: Sendable, Hashable {
  public static let all = PageRequest(validOffset: 0, limit: nil)

  public let offset: Int
  public let limit: Int?

  public init(offset: Int, limit: Int?) throws(MemoirReadError) {
    guard offset >= 0, limit.map({ $0 > 0 }) ?? true else { throw .invalidPage(offset: offset, limit: limit ?? 0) }
    self.init(validOffset: offset, limit: limit)
  }

  private init(validOffset offset: Int, limit: Int?) {
    self.offset = offset
    self.limit = limit
  }

  func slice<Item>(_ items: [Item]) -> [Item] {
    guard offset < items.count else { return [] }
    let end = limit.map { min(items.count, offset + $0) } ?? items.count
    return Array(items[offset..<end])
  }
}

public struct ReadPage<Item: Sendable & Equatable>: Sendable, Equatable {
  public let items: [Item]
  public let total: Int
  public let offset: Int

  init(_ matched: [Item], page: PageRequest) {
    items = page.slice(matched)
    total = matched.count
    offset = page.offset
  }

  public var hasMore: Bool { offset + items.count < total }
}
