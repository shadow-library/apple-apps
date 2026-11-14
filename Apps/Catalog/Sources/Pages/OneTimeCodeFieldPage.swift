@_spi(Preview) import ShadowDesignSystem
import SwiftUI

struct OneTimeCodeFieldPage: View {
  @State private var isShowingSheet = false

  var body: some View {
    ComponentPage(component: .oneTimeCodeField) {
      StateSection(
        "Identity verification",
        note: "One hidden field drives the boxes, so AutoFill, paste and VoiceOver treat them as one. From Passwords: 482 913 fills it from the keyboard bar."
      ) {
        VerificationCard(code: "482", isFocused: true)
      }
      StateSection("Try it", note: "Type or paste a code. 482913 verifies; any other code shows the error, keeps the digits and selects them so the next code replaces them.") {
        LiveVerification()
          .shadowCard()
      }
      StateSection("Empty") {
        VerificationCard(code: "")
      }
      StateSection("Complete", note: "The last digit submits on its own, once per code.") {
        VerificationCard(code: "482913")
      }
      StateSection("Verifying", note: "Input pauses while the code is checked; focus stays so a retry needs no tap.") {
        VerificationCard(code: "482913")
          .shadowVerifying(Text("Verifying…"))
      }
      StateSection("Error", note: "The boxes keep the code and select it, so typing replaces it. The row shakes once; with Reduce Motion only the colour changes.") {
        VerificationCard(code: "551004", isFocused: true)
          .shadowValidation(Text("That code didn’t match. Check your authenticator app and try again."))
        VerificationCard(code: "551004")
          .shadowValidation(Text("That code has expired. Enter the new one."))
      }
      StateSection("Disabled") {
        VerificationCard(code: "48")
          .disabled(true)
      }
      StateSection("Lengths and grouping", note: "Six digits group 3 + 3. Four digits stay in one group. Alphanumeric recovery codes take letters and a dash between groups.") {
        VStack(alignment: .leading, spacing: Spacing.space5) {
          CodeSample(code: "2024", format: ShadowOneTimeCode(length: 4))
          CodeSample(code: "K7Q2M9", format: ShadowOneTimeCode(length: 8, characters: .alphanumeric), separator: .dash, isFocused: true)
        }
        .shadowCard()
      }
      StateSection("In a sheet", note: "The Identity step-up sheet. On iPhone the number pad opens with the Passwords suggestion above it.") {
        Button("Verify it’s you", systemImage: "lock.shield") { isShowingSheet = true }
          .buttonStyle(.shadowTinted)
          .sheet(isPresented: $isShowingSheet) { VerificationSheet() }
      }
    }
  }
}

private struct VerificationCard: View {
  @State var code: String
  var isFocused: Bool?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      VerificationHeader()
      ShadowOneTimeCodeField("Verification code", code: $code, value: digitsEntered) { _ in }
        .shadowPreviewFieldFocus(isFocused)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .shadowCard()
  }
}

private struct VerificationHeader: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Text("Enter the code")
        .shadowFont(.headline)
        .foregroundStyle(ShadowColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
      Text("Enter the 6-digit code from your authenticator app.")
        .shadowFont(ShadowDensity.current == .touch ? .subheadline : .footnote)
        .foregroundStyle(ShadowColor.textSecondary)
    }
  }
}

private struct CodeSample: View {
  @State var code: String
  let format: ShadowOneTimeCode
  var separator = ShadowOneTimeCodeSeparator.space
  var isFocused: Bool?

  var body: some View {
    ShadowOneTimeCodeField("Recovery code", code: $code, format: format, separator: separator, value: charactersEntered) { _ in }
      .shadowPreviewFieldFocus(isFocused)
  }
}

private struct LiveVerification: View {
  private enum Status: Equatable {
    case editing
    case verifying
    case failed
    case verified
  }

  @State private var code = ""
  @State private var status = Status.editing

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      VerificationHeader()
      ShadowOneTimeCodeField(
        "Verification code", code: $code, hint: "Enter the 6-digit code from your authenticator app.", value: digitsEntered, onComplete: verify
      )
      .shadowVerifying(status == .verifying ? Text("Verifying…") : nil)
      .shadowValidation(status == .failed ? Text("That code didn’t match. Check your authenticator app and try again.") : nil)
      .onChange(of: code) { if status == .failed || status == .verified { status = .editing } }
      if status == .verified {
        Label("Verified", systemImage: "checkmark.circle.fill")
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.successText)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func verify(_ code: String) {
    status = .verifying
    Task {
      try? await Task.sleep(for: .seconds(1.2))
      status = code == "482913" ? .verified : .failed
    }
  }
}

private struct VerificationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var code = ""

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        VerificationHeader()
        ShadowOneTimeCodeField("Verification code", code: $code, value: digitsEntered) { _ in dismiss() }
        Spacer(minLength: 0)
      }
      .padding(Spacing.space5)
      .navigationTitle("Verify it’s you")
      #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
    }
    .presentationDetents([.medium])
    #if os(macOS)
      .frame(minWidth: 420, minHeight: 260)
    #endif
  }
}

private func digitsEntered(_ progress: ShadowOneTimeCodeProgress) -> Text {
  Text("\(progress.entered) of \(progress.length) digits entered")
}

private func charactersEntered(_ progress: ShadowOneTimeCodeProgress) -> Text {
  Text("\(progress.entered) of \(progress.length) characters entered")
}
