import AuthenticationServices
import ShadowAI
import ShadowDesignSystem
import SwiftUI

struct OpenRouterSignInButton: View {
  let model: AISettingsModel
  @Environment(\.webAuthenticationSession) private var session

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(spacing: Spacing.space2) {
        Button {
          Task { await model.signInWithOpenRouter(using: Self.signIn(with: session)) }
        } label: {
          Label {
            Text("Sign In with OpenRouter", tableName: "AISettings", bundle: .module)
          } icon: {
            Image(systemName: "person.badge.key")
          }
        }
        .disabled(model.signIn == .signingIn)
        if model.signIn == .signingIn {
          ProgressView {
            Text("Signing in with OpenRouter", tableName: "AISettings", bundle: .module)
          }
          .labelsHidden()
          .controlSize(.small)
        }
      }
      if case .failed(let error) = model.signIn { ShadowValidationMessage(error.text) }
      Text("Or paste a key you made on OpenRouter's site.", tableName: "AISettings", bundle: .module)
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
    }
  }

  static func signIn(with session: WebAuthenticationSession) -> WebSignIn {
    { (url, scheme) async throws(ModelError) -> URL in
      do {
        return try await session.authenticate(using: url, callback: .customScheme(scheme), preferredBrowserSession: nil, additionalHeaderFields: [:])
      } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
        throw .cancelled
      } catch let error as URLError {
        throw .transport(error.code)
      } catch {
        throw .invalidRequest("The sign-in page could not be shown.")
      }
    }
  }
}
