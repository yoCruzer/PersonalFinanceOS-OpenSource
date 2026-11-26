import Foundation

/// A narrow, read-only purpose proof shared by installation, suggestions and import.
/// Names alone never establish compatibility; kind, leaf and recognized root must agree.
enum CategoryPurposeCompatibility {
    static let chargingKey = "expense.vehicle.charging"

    static func matches(semanticKey: String, kind: CategoryKind, name: String, storageKey: String,
                        parentKind: CategoryKind?, parentName: String?, parentKey: String?, parentIsRoot: Bool) -> Bool {
        guard semanticKey == chargingKey, kind == .expense, name == "充电",
              storageKey.isEmpty || storageKey == chargingKey,
              parentKind == .expense, parentIsRoot else { return false }
        switch parentName {
        case "交通": return parentKey == "" || parentKey == "expense.transportation"
        case "车辆养护": return parentKey == "" || parentKey == "expense.vehicle"
        default: return false
        }
    }
}
