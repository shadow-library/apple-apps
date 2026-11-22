import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// The currencies the vault uses (`enabledCurrencies`, `account.service.ts:164-165`): the home currency always, and the others the owner spends in.
struct EnabledCurrenciesView: View {
  @State private var model: SettingsModel

  init(context: MemoirScreenContext) {
    _model = State(initialValue: SettingsModel(context: context))
  }

  var body: some View {
    List {
      if let account = model.account {
        Section {
          ForEach(SettingsCurrencies.ordered(Set(SettingsCurrencies.supported).union(account.enabledCurrencies), home: account.defaultCurrency), id: \.self) {
            currency in
            Toggle(
              isOn: Binding(
                get: { account.enabledCurrencies.contains(currency) || currency == account.defaultCurrency },
                set: { enabled in Task { await model.setCurrency(currency, enabled: enabled) } })
            ) {
              Text(verbatim: SettingsCurrencies.label(currency))
            }
            .disabled(currency == account.defaultCurrency || model.saving.contains(.currencies))
          }
        } footer: {
          Text("Your home currency is always on. Spend in another currency keeps its own and converts to your home currency.", tableName: "Settings")
        }
        if let error = model.failure(for: .currencies) {
          Section { ShadowValidationMessage(error.text) }
        }
      } else if case .failed(let error) = model.snapshot.state {
        ShadowCallout(Text("Your settings couldn’t be loaded", tableName: "Settings"), message: error.text, intent: .danger)
      }
    }
    .navigationTitle(Text("Currencies", tableName: "Settings"))
    .shadowScreen(.pushed)
    .task { await model.run() }
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack {
      EnabledCurrenciesView(context: context)
    }
    .shadowTheme()
  }
}
