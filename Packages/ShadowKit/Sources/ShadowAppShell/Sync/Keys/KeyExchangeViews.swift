import ShadowDesignSystem
import SwiftUI

/// The device that needs the key: show this device's code, scan the answer, then type the other device's six digits.
struct KeyRequestView: View {
  @Environment(\.appIdentity) private var app
  let model: KeyRequestModel
  let close: () -> Void
  @State private var isScanning = false

  var body: some View {
    @Bindable var model = model
    KeyFlowSection(title: Text("Scan from Another Device", tableName: "SyncKeys", bundle: .module), failure: model.failure) {
      switch model.step {
      case .showingRequest(let payload):
        if isScanning {
          KeyCodeReader(
            prompt: Text("Scan the code your other device now shows.", tableName: "SyncKeys", bundle: .module), isEnabled: true, onRead: model.received)
        } else {
          Text(
            "On a device that already has your \(app.vaultNoun), open Sync Settings, then Keys and Devices, choose Send the Key to Another Device and scan this code.",
            tableName: "SyncKeys", bundle: .module
          )
          .foregroundStyle(ShadowColor.textSecondary)
          KeyCodeImage(payload: payload)
          KeyCodeCopyButton(payload: payload)
        }
      case .enteringCode, .adding:
        Text("Type the six-digit code your other device shows. If it is not the code you expected, cancel.", tableName: "SyncKeys", bundle: .module)
          .foregroundStyle(ShadowColor.textSecondary)
        TextField(text: $model.code, prompt: Text(verbatim: "000000")) { Text("Code from the other device", tableName: "SyncKeys", bundle: .module) }
          .shadowField()
          .monospacedDigit()
          .autocorrectionDisabled()
          #if os(iOS)
            .keyboardType(.numberPad)
          #endif
          .textContentType(.oneTimeCode)
          .onSubmit { Task { await model.add() } }
          .disabled(model.step == .adding)
        if model.step == .adding { KeyFlowProgress(text: Text("Adding the key…", tableName: "SyncKeys", bundle: .module)) }
      case .finished:
        ShadowCallout(Text("Your \(app.vaultNoun)'s key is on this device.", tableName: "SyncKeys", bundle: .module), intent: .success, systemImage: "key") { EmptyView() }
      case .ended(let reason):
        ShadowCallout(Text(verbatim: reason.headline), intent: .warning, systemImage: "xmark.octagon") { EmptyView() }
      }
    } footer: {
      footer
    }
  }

  @ViewBuilder
  private var footer: some View {
    switch model.step {
    case .showingRequest:
      Button {
        isScanning.toggle()
      } label: {
        isScanning ? Text("Show This Device's Code", tableName: "SyncKeys", bundle: .module) : Text("Next: Scan Their Code", tableName: "SyncKeys", bundle: .module)
      }
      .buttonStyle(isScanning ? .shadowBordered : .shadowFilled)
      Spacer(minLength: Spacing.space3)
      cancel
    case .enteringCode, .adding:
      Spacer(minLength: Spacing.space3)
      cancel.disabled(model.step == .adding)
      Button {
        Task { await model.add() }
      } label: {
        Text("Add Key", tableName: "SyncKeys", bundle: .module)
      }
      .buttonStyle(.shadowFilled)
      .disabled(!model.canAdd)
    case .finished, .ended:
      Spacer(minLength: Spacing.space3)
      Button(action: close) {
        Text("Done", tableName: "SyncKeys", bundle: .module)
      }
      .buttonStyle(.shadowFilled)
    }
  }

  private var cancel: some View {
    Button(action: close) {
      Text("Cancel", tableName: "SyncKeys", bundle: .module)
    }
    .buttonStyle(.shadowBordered)
  }
}

/// The device that holds the key: scan the other device's code, show the answer, and only once it is scanned, show the six digits to type there.
struct KeyResponseView: View {
  let model: KeyResponseModel
  let close: () -> Void

  var body: some View {
    KeyFlowSection(title: Text("Send the Key to Another Device", tableName: "SyncKeys", bundle: .module), failure: model.failure) {
      switch model.step {
      case .awaitingRequest, .answering:
        KeyCodeReader(
          prompt: Text("On the device that needs the key, choose Scan from Another Device, then scan the code it shows.", tableName: "SyncKeys", bundle: .module),
          isEnabled: model.step == .awaitingRequest
        ) { text in Task { await model.received(text) } }
        if model.step == .answering { KeyFlowProgress(text: Text("Preparing the answer…", tableName: "SyncKeys", bundle: .module)) }
      case .showingResponse(let payload):
        Text("Scan this code with the other device.", tableName: "SyncKeys", bundle: .module).foregroundStyle(ShadowColor.textSecondary)
        KeyCodeImage(payload: payload)
        KeyCodeCopyButton(payload: payload)
      case .showingCode(_, let code):
        Text("Type this code on the other device. Its key is added only if the codes match.", tableName: "SyncKeys", bundle: .module).foregroundStyle(ShadowColor.textSecondary)
        Text(verbatim: Self.grouped(code))
          .shadowFont(.largeTitle)
          .monospacedDigit()
          .foregroundStyle(ShadowColor.textPrimary)
          .frame(maxWidth: .infinity)
          .accessibilityLabel(Text(verbatim: code.map(String.init).joined(separator: " ")))
      }
    } footer: {
      switch model.step {
      case .showingResponse:
        Spacer(minLength: Spacing.space3)
        cancel
        Button(action: model.otherDeviceScanned) {
          Text("The Other Device Scanned It", tableName: "SyncKeys", bundle: .module)
        }
        .buttonStyle(.shadowFilled)
      case .showingCode:
        Spacer(minLength: Spacing.space3)
        Button(action: close) {
          Text("Done", tableName: "SyncKeys", bundle: .module)
        }
        .buttonStyle(.shadowFilled)
      case .awaitingRequest, .answering:
        Spacer(minLength: Spacing.space3)
        cancel.disabled(model.step == .answering)
      }
    }
  }

  private var cancel: some View {
    Button(action: close) {
      Text("Cancel", tableName: "SyncKeys", bundle: .module)
    }
    .buttonStyle(.shadowBordered)
  }

  private static func grouped(_ code: String) -> String {
    "\(code.prefix(3)) \(code.dropFirst(3))"
  }
}
