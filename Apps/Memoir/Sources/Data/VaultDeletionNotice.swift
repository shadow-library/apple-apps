import ShadowDesignSystem
import SwiftUI

extension View {
  /// The deletion's outcome, shown over whatever the reopened vault brings up, since the screen that started it has gone with the old vault.
  func vaultDeletionNotice(_ deletion: MemoirVaultDeletion) -> some View {
    modifier(VaultDeletionNotice(deletion: deletion))
  }
}

private struct VaultDeletionNotice: ViewModifier {
  let deletion: MemoirVaultDeletion

  func body(content: Content) -> some View {
    content.alert(title, isPresented: Binding(get: { deletion.notice != nil }, set: { if !$0 { deletion.notice = nil } })) {
      Button(role: .cancel) {
        deletion.notice = nil
      } label: {
        Text("OK", tableName: "Data")
      }
    } message: {
      message
    }
  }

  private var title: Text {
    switch deletion.notice {
    case .incomplete: Text("Some of your data couldn’t be erased", tableName: "Data")
    case .erased, nil: Text("Your data has been erased", tableName: "Data")
    }
  }

  private var message: Text {
    switch deletion.notice {
    case .incomplete(let code):
      Text("Memoir opened again with what was left. Delete your data again from Settings to remove the rest. (\(code))", tableName: "Data")
    case .erased, nil:
      Text("Everything Memoir kept on this device is gone. What sync already sent stays at its location until you remove it there.", tableName: "Data")
    }
  }
}
