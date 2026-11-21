import ShadowDesignSystem
import ShadowSyncS3
import SwiftUI

struct SyncS3FormView: View {
  let model: SyncConnectModel

  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: Spacing.space3) {
      field(.endpoint, title: Text("Endpoint", tableName: "SyncSettings"), text: $model.s3.endpoint, prompt: Text(verbatim: "https://s3.eu-west-1.amazonaws.com"))
      field(.region, title: Text("Region", tableName: "SyncSettings"), text: $model.s3.region, prompt: Text(verbatim: "eu-west-1"))
      field(.bucket, title: Text("Bucket", tableName: "SyncSettings"), text: $model.s3.bucket, prompt: Text("my-novels", tableName: "SyncSettings"))
      field(.keyPrefix, title: Text("Folder in the bucket (optional)", tableName: "SyncSettings"), text: $model.s3.keyPrefix, prompt: Text("None", tableName: "SyncSettings"))
      Picker(selection: $model.s3.addressing) {
        Text("Virtual-hosted", tableName: "SyncSettings").tag(S3Configuration.AddressingStyle.virtualHosted)
        Text("Path-style", tableName: "SyncSettings").tag(S3Configuration.AddressingStyle.path)
      } label: {
        Text("Addressing", tableName: "SyncSettings")
      }
      .pickerStyle(.segmented)
      field(.credentials, title: Text("Access key ID", tableName: "SyncSettings"), text: $model.s3.accessKeyID, prompt: nil, showsIssue: false)
      VStack(alignment: .leading, spacing: Spacing.space1) {
        Text("Secret access key", tableName: "SyncSettings").shadowFont(.subheadline)
        SecureField(text: edited($model.s3.secretAccessKey)) {
          Text("Secret access key", tableName: "SyncSettings")
        }
        .shadowField()
        .textContentType(.password)
        .autocorrectionDisabled()
        .onSubmit { Task { await model.submitS3() } }
        if let issue = model.s3Issue, issue.field == .credentials { ShadowValidationMessage(Text(verbatim: issue.message)) }
      }
      Text(
        "The keys need permission to list, read, write and delete in the bucket. They are kept in your keychain, which shares them with your other devices, and never in the library.",
        tableName: "SyncSettings"
      )
      .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      HStack {
        Spacer(minLength: Spacing.space3)
        Button {
          Task { await model.submitS3() }
        } label: {
          Text("Check and Continue", tableName: "SyncSettings")
        }
        .buttonStyle(.shadowFilled)
        .disabled(!model.s3.isComplete)
      }
    }
  }

  private func field(_ field: SyncS3Form.Field, title: Text, text: Binding<String>, prompt: Text?, showsIssue: Bool = true) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      title.shadowFont(.subheadline)
      TextField(text: edited(text), prompt: prompt) { title }
        .shadowField()
        .autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.never)
          .keyboardType(field == .endpoint ? .URL : .asciiCapable)
        #endif
      if showsIssue, let issue = model.s3Issue, issue.field == field { ShadowValidationMessage(Text(verbatim: issue.message)) }
    }
  }

  private func edited(_ text: Binding<String>) -> Binding<String> {
    Binding(
      get: { text.wrappedValue },
      set: {
        text.wrappedValue = $0
        model.s3Edited()
      })
  }
}
