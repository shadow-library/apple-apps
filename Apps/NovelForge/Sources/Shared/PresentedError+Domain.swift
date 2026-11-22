import NovelForgeCore
import ShadowAppShell

extension PresentedError {
  init(_ error: any Error, known: (DomainError) -> String?) {
    guard let domain = error as? DomainError else {
      self.init(error)
      return
    }
    if case .store(let store) = domain {
      self.init(store)
    } else {
      self.init(headline: known(domain) ?? Self.genericHeadline, detail: domain.code)
    }
  }
}
