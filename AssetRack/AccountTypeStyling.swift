import SwiftUI

// MARK: - Per-type accent colour
//
// Centralised so the onboarding tour, the Add Account flow, the accounts list,
// and anywhere else that draws a type-tagged badge all agree on which colour
// belongs to which account type. Keep this file SwiftUI-only — the model layer
// in `Models.swift` deliberately doesn't import SwiftUI.

extension AccountCategory {
    /// Brand colour used wherever a chart, segment, or badge represents this
    /// category — dashboard history, projection stacked area, allocation pie,
    /// account-row icons, the Add Account picker. Single source of truth so
    /// the screens never drift out of sync.
    var accentColor: Color {
        switch self {
        case .cashAndBank:  return .teal
        case .investments:  return .blue
        case .pension:      return .purple
        case .realEstate:   return .indigo
        case .liabilities:  return .red
        }
    }
}

extension AccountType {
    /// Per-type accent. Delegates to the owning category so adding a new
    /// account type doesn't require picking a new colour — and so all types in
    /// a category render identically in lists and pickers.
    var accentColor: Color { category.accentColor }
}
