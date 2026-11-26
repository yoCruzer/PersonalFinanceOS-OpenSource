import Foundation

/// Cloud cursors belong to an environment/account; wire identities belong to the local ledger.
struct CloudReplicaLocation {
    enum Environment: String {
        case development = "Development"
        case production = "Production"
    }

    let root: URL
    let environment: Environment
    let account: String

    var identityURL: URL { root.appendingPathComponent("identities.json") }

    var stateURL: URL {
        root.appendingPathComponent(environment.rawValue)
            .appendingPathComponent(PrivateCloudReplicaSession.recordName(for: account))
            .appendingPathComponent("replica.json")
    }
}
