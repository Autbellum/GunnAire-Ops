import SwiftUI
import UIKit

extension View {
    /// iPad's decimal pad can present a floating popover over nearby controls.
    /// Use its standard numeric keyboard; iPhone keeps the compact decimal pad.
    func catalogNumericKeyboard() -> some View {
        keyboardType(UIDevice.current.userInterfaceIdiom == .pad ? .numbersAndPunctuation : .decimalPad)
    }
}

/// Appears only for inventory. Field-created items can wait for an admin's
/// accounting choices; ordinary service creation stays uncluttered.
struct QuickBooksInventorySetupSection: View {
    @Binding var setup: QuickBooksInventorySetup
    let accounts: [QuickBooksAccount]
    let scope: QuickBooksChangeHistoryScope?

    var body: some View {
        Section("Inventory Setup") {
            TextField("Opening quantity", value: $setup.openingQuantity, format: .number)
                .catalogNumericKeyboard()
                .accessibilityIdentifier("InventoryOpeningQuantity")
            TextField("Opening date (YYYY-MM-DD)", text: Binding(
                get: { setup.openingDate ?? "" }, set: { setup.openingDate = $0.isEmpty ? nil : $0 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("InventoryOpeningDate")
            if let prior = setup.scope, prior != scope {
                Text("These accounting choices belong to another QuickBooks connection. The draft is retained; choose the current business only after reviewing the item.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Choose Current Business Accounts") {
                    setup.scope = scope
                    setup.assetAccount = nil; setup.incomeAccount = nil; setup.expenseAccount = nil
                }
                .disabled(scope == nil)
            } else {
                accountPicker(.asset, keyPath: \.assetAccount)
                accountPicker(.income, keyPath: \.incomeAccount)
                accountPicker(.expense, keyPath: \.expenseAccount)
            }
            Text("Opening stock is used only when QuickBooks creates a new item. Linking an existing item keeps its current QuickBooks balance. Truck stock is recorded separately.")
                .font(.caption).foregroundStyle(.secondary)
            if scope == nil || accounts.isEmpty {
                Text("You can save this draft offline. An administrator can sync the chart of accounts and complete setup before publishing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func accountPicker(_ role: QuickBooksInventorySetup.AccountRole,
                               keyPath: WritableKeyPath<QuickBooksInventorySetup, QuickBooksReference?>) -> some View {
        let eligible = accounts.filter(role.accepts)
        return Picker(role.rawValue, selection: Binding(
            get: { setup[keyPath: keyPath]?.value ?? "" },
            set: { identifier in
                guard let scope, setup.scope == nil || setup.scope == scope else { return }
                setup.scope = scope
                setup[keyPath: keyPath] = eligible.first { $0.Id == identifier }?.reference
            }
        )) {
            Text("Choose account").tag("")
            if let saved = setup[keyPath: keyPath], !eligible.contains(where: { $0.Id == saved.value }) {
                Text("\(saved.name ?? "Saved account") — refresh to review").tag(saved.value)
            }
            ForEach(eligible) { account in Text(account.displayName).tag(account.Id) }
        }
        .disabled(scope == nil)
        .accessibilityIdentifier("InventoryAccount-\(role.id)")
    }
}

struct QuickBooksInventoryBalanceSection: View {
    let item: Item
    var body: some View {
        Section("QuickBooks Inventory") {
            if let details = item.catalogDetails {
                LabeledContent("Quantity on hand", value: details.quantityOnHand?.formatted() ?? "Needs refresh")
                LabeledContent("Original opening date", value: details.inventoryStartDate ?? "Needs refresh")
                LabeledContent("Inventory asset", value: details.assetAccount?.displayName ?? "Needs refresh")
                LabeledContent("Sales income", value: details.incomeAccount?.displayName ?? "Needs refresh")
                LabeledContent("Cost of goods sold", value: details.expenseAccount?.displayName ?? "Needs refresh")
            } else {
                Text("Refresh the catalog to read the original item's inventory details.")
            }
            Text("This is the company-wide balance last read from QuickBooks, not live truck stock. Price edits do not adjust stock, opening dates or accounting accounts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
