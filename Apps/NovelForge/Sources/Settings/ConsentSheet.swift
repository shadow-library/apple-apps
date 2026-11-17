import Observation
import ShadowAI
import ShadowDesignSystem
import ShadowStore
import SwiftUI

@MainActor
@Observable
final class ConsentPromptModel {
  let request: AIConsentRequest
  let disclosure: ConsentDisclosure?
  private(set) var isBusy = false
  private(set) var failure: PresentedError?
  private let services: AIServices
  private let store: VaultStore

  init(request: AIConsentRequest, services: AIServices, store: VaultStore) {
    self.request = request
    self.services = services
    self.store = store
    disclosure = ConsentDisclosure(request)
  }

  var canAllow: Bool { disclosure != nil && !isBusy }

  func allow() async -> Bool {
    guard canAllow else { return false }
    isBusy = true
    defer { isBusy = false }
    do {
      try await services.grant(request, in: store)
      failure = nil
      return true
    } catch {
      failure = AIErrors.presented(error)
      return false
    }
  }
}

struct ConsentSheet: View {
  @State private var model: ConsentPromptModel
  let onAllowed: () -> Void
  let onDeclined: () -> Void

  init(request: AIConsentRequest, services: AIServices, store: VaultStore, onAllowed: @escaping () -> Void, onDeclined: @escaping () -> Void) {
    _model = State(initialValue: ConsentPromptModel(request: request, services: services, store: store))
    self.onAllowed = onAllowed
    self.onDeclined = onDeclined
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        if let failure = model.failure { ShadowValidationMessage(failure.text) }
        destination
        explanation
        Text("You can revoke this at any time in AI settings.", tableName: "Settings").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      .padding(.bottom, Spacing.space1)
    }
    .scrollBounceBehavior(.basedOnSize)
    .shadowSheetHeader(
      Text("Send this to \(model.request.provider.displayName)?", tableName: "Settings"),
      cancel: ShadowSheetCancel(Text("Don't Allow", tableName: "Settings"), isDisabled: model.isBusy, action: onDeclined),
      confirm: ShadowSheetConfirm(Text("Allow", tableName: "Settings"), isDisabled: !model.canAllow, submitShortcut: true) {
        Task {
          if await model.allow() { onAllowed() }
        }
      }
    )
    .shadowSheetStyle(.form)
    .interactiveDismissDisabled(model.isBusy)
  }

  private var destination: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Text(verbatim: model.request.provider.displayName).shadowFont(.headline)
      Text(verbatim: model.request.host).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).textSelection(.enabled)
    }
  }

  @ViewBuilder
  private var explanation: some View {
    if let disclosure = model.disclosure {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Text(verbatim: disclosure.title).shadowFont(.subheadline)
        Text(verbatim: disclosure.explanation(provider: model.request.provider.displayName))
      }
    } else {
      ShadowCallout(
        Text("This request needs a newer version of Novel Forge.", tableName: "Settings"),
        message: Text("It describes data this version cannot explain, so nothing can be allowed here.", tableName: "Settings"), intent: .warning,
        systemImage: "exclamationmark.triangle"
      ) { EmptyView() }
    }
  }
}

extension View {
  func aiConsentSheet(_ request: Binding<AIConsentRequest?>, services: AIServices, store: VaultStore, onAllowed: @escaping () -> Void) -> some View {
    sheet(isPresented: Binding(get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } })) {
      if let pending = request.wrappedValue {
        ConsentSheet(
          request: pending, services: services, store: store,
          onAllowed: {
            request.wrappedValue = nil
            onAllowed()
          },
          onDeclined: { request.wrappedValue = nil })
      }
    }
  }
}
