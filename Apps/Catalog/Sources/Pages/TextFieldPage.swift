@_spi(Preview) import ShadowDesignSystem
import SwiftUI

struct TextFieldPage: View {
  @State private var email = "ada@shadowlibrary.app"
  @State private var password = "hunter2hunter"
  @State private var displayName = "a"
  @State private var homePage = ""
  @State private var acsURL = "idp.example/saml"
  @State private var allowedRanges = ""
  @State private var handle = "ada"
  @State private var amount = "42"
  @State private var longValue = "https://shadowlibrary.app/library/the-ninth-archive/chapter-42-the-glass-stair?utm_source=newsletter"
  @State private var formName = "Ada Lovelace"
  @State private var formEmail = "ada@shadowlibrary.app"
  @State private var formWebsite = ""
  @State private var firstName = ""
  @State private var lastName = ""
  @FocusState private var focus: Name?
  @Environment(\.catalogTakesSnapshot) private var takesSnapshot

  private enum Name: Hashable { case first, last }

  var body: some View {
    ComponentPage(component: .textField) {
      StateSection(
        "Default and focused",
        note:
          "A recessed surface-well field on iPhone and iPad; the focused field lifts to surface-card with a border-focus edge and a soft halo. Mac keeps the native bordered field."
      ) {
        FieldStack {
          FieldRow(title: "Email or phone") {
            TextField("Email or phone", text: $email)
              .textContentType(.emailAddress)
              .shadowField()
          }
          FieldRow(title: "Display name") {
            TextField("Display name", text: $formName)
              .textContentType(.name)
              .shadowField()
              .shadowPreviewFieldFocus(true)
          }
          FieldRow(title: "Home page URL", help: "Placeholder text is a hint, never the label.", isWide: true) {
            TextField("Home page URL", text: $homePage, prompt: Text("https://"))
              .textContentType(.URL)
              .shadowField()
          }
        }
      }
      StateSection(
        "Caller-owned focus",
        note:
          "Apply your own .focused outside .shadowField and pass the same state in, so the focused look follows it. Return moves to the next field. Mac screenshots focus First name to show the state."
      ) {
        FieldStack {
          FieldRow(title: "First name") {
            TextField("First name", text: $firstName, prompt: Text("Ada"))
              .focused($focus, equals: .first)
              .shadowField(isFocused: focus == .first)
              .submitLabel(.next)
              .onSubmit { focus = .last }
          }
          FieldRow(title: "Last name") {
            TextField("Last name", text: $lastName, prompt: Text("Lovelace"))
              .focused($focus, equals: .last)
              .shadowField(isFocused: focus == .last)
          }
        }
        #if os(macOS)
          .task {
            guard takesSnapshot else { return }
            try? await Task.sleep(for: .milliseconds(300))
            focus = .first
          }
        #endif
      }
      StateSection("Secure field", note: "Password fields always carry a show toggle. Toggling keeps the caret and the keyboard.") {
        FieldStack {
          FieldRow(title: "Password", help: "You’ll be signed out of other devices after resetting.") {
            ShadowPasswordField("Password", text: $password, showLabel: "Show password", hideLabel: "Hide password")
              .shadowPreviewFieldFocus(true)
          }
          FieldRow(title: "Confirm password") {
            ShadowPasswordField("Confirm password", text: .constant(""), showLabel: "Show password", hideLabel: "Hide password")
          }
        }
      }
      StateSection("Error", note: "The message says how to fix it and pairs a symbol with destructive-label text, so state never depends on colour alone.") {
        FieldStack {
          FieldRow(title: "Display name") {
            TextField("Display name", text: $displayName)
              .shadowField()
              .shadowValidation(displayName.count < 2 ? Text("Use at least 2 characters.") : nil)
          }
          FieldRow(title: "ACS URL", isWide: true) {
            TextField("ACS URL", text: $acsURL)
              .textContentType(.URL)
              .shadowField()
              .shadowValidation(acsURL.hasPrefix("https://") ? nil : Text("Enter a URL that starts with https://"))
          }
          FieldRow(title: "ACS URL, focused", isWide: true) {
            TextField("ACS URL", text: $acsURL)
              .shadowField()
              .shadowValidation(Text("Enter a URL that starts with https://"))
              .shadowPreviewFieldFocus(true)
          }
        }
      }
      StateSection("Disabled", note: "Fades to disabled-opacity and ignores input.") {
        FieldStack {
          FieldRow(title: "Allowed IP ranges", help: "Leave empty to allow every network.") {
            TextField("Allowed IP ranges", text: $allowedRanges, prompt: Text("10.0.0.0/8"))
              .shadowField()
              .disabled(true)
          }
          FieldRow(title: "Email") {
            TextField("Email", text: $email)
              .shadowField()
              .disabled(true)
          }
        }
      }
      StateSection("Prefix and suffix", note: "Fixed context goes inside the field, so the typed value stays short.") {
        FieldStack {
          FieldRow(title: "Handle", isWide: true) {
            TextField("Handle", text: $handle)
              .shadowField(leading: { Text("@") }, trailing: { Text("on Shadow Library").shadowFont(.footnote) })
          }
          FieldRow(title: "Pledge", isWide: true) {
            TextField("Pledge", text: $amount)
              #if !os(macOS)
                .keyboardType(.decimalPad)
              #endif
              .monospacedDigit()
              .shadowField(leading: { Image(systemName: "dollarsign") }, trailing: { Text("per month").shadowFont(.footnote) })
          }
        }
      }
      StateSection("Long value", note: "The value scrolls inside the field; the field never grows taller.") {
        FieldStack {
          FieldRow(title: "Home page URL", isWide: true) {
            TextField("Home page URL", text: $longValue)
              .shadowField()
          }
        }
      }
      StateSection("In a form", note: "Rows in an inset-grouped Form keep the native layout; the label sits in the row and the tint carries focus.") {
        FormBlock {
          FormSection {
            LabeledContent("Name") {
              TextField("Name", text: $formName)
                .textContentType(.name)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
            }
            LabeledContent("Email") {
              TextField("Email", text: $formEmail)
                .textContentType(.emailAddress)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
            }
            LabeledContent("Website") {
              TextField("Website", text: $formWebsite, prompt: Text("https://"))
                .textContentType(.URL)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
            }
          } footer: {
            Text("Shown on your public profile.")
          }
        }
      }
    }
  }
}
