import CloudKit
import Foundation

/// Whitelisted diagnostics only. Never serialize messages, userInfo, record names or payloads.
enum SyncCoordinationFailure: Error { case serviceBackoff(TimeInterval) }

struct SyncFailure: Codable, Equatable, Sendable {
    let phase: String
    let domain: String
    let code: Int
    let retryAfter: Double?
    let count: Int
    let retryable: Bool
    var reasonCode: String? = nil

    var recoveryMessage: String? {
        guard domain == "CloudKit" else { return nil }
        switch CKError.Code(rawValue: code) {
        case .notAuthenticated: return "请在系统设置登录 iCloud 后重试，本机记账不受影响。"
        case .permissionFailure: return "当前账户或同步权限受限。请检查系统 iCloud 设置；若仍失败，请导出脱敏诊断。"
        case .badContainer, .missingEntitlement: return "当前同步配置无法继续，请导出脱敏诊断联系支持。"
        default: return nil
        }
    }

    static func capture(_ error: Error, phase: String, count: Int = 1) -> Self {
        if case let SyncCoordinationFailure.serviceBackoff(delay) = error {
            return Self(phase: phase, domain: "Application", code: 1201, retryAfter: delay,
                count: count, retryable: true, reasonCode: "service_backoff_pending")
        }
        let reason: (Int, String)?
        switch error {
        case ProtectedLedgerReplica.Failure.initialFetchRequired: reason = (1001, "projection_not_ready")
        case ProtectedLedgerReplica.Failure.differentAccount: reason = (1002, "account_mismatch")
        case ProtectedLedgerReplica.Failure.unsupportedFormat: reason = (1003, "unsupported_replica_format")
        case ProtectedLedgerReplica.Failure.conflictingRevision: reason = (1004, "conflicting_revision")
        case ProtectedLedgerReplica.Failure.clockExhausted: reason = (1005, "revision_clock_exhausted")
        case ProtectedLedgerReplica.Failure.malformedRecord: reason = (1006, "invalid_replica_record")
        case ReconcileRevision.Failure.stalePlan: reason = (1101, "stale_projection")
        case is CancellationError: reason = (1102, "operation_cancelled")
        case is NativeBackupError: reason = (1103, "invalid_ledger_projection")
        default: reason = nil
        }
        if let reason {
            return Self(phase: phase, domain: "Application", code: reason.0, retryAfter: nil,
                count: count, retryable: false, reasonCode: reason.1)
        }
        let ns = error as NSError
        let domain: String
        switch ns.domain {
        case CKErrorDomain: domain = "CloudKit"
        case NSCocoaErrorDomain: domain = "Cocoa"
        case NSPOSIXErrorDomain: domain = "POSIX"
        default: domain = "Application"
        }
        let ck = error as? CKError
        let delay = ck?.retryAfterSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return Self(phase: phase, domain: domain, code: domain == "Application" ? 0 : ns.code,
            retryAfter: delay, count: count, retryable: ck.map { isTransient($0) && !(phase == "activation" && $0.code == .notAuthenticated) } ?? false)
    }

    static func isTransient(_ error: CKError) -> Bool {
        switch error.code {
        case .notAuthenticated, .accountTemporarilyUnavailable, .networkFailure, .networkUnavailable,
             .requestRateLimited, .serviceUnavailable, .zoneBusy, .operationCancelled: true
        default: false
        }
    }

    static func grouped(_ errors: [CKError], phase: String) -> [Self] {
        let groups = Dictionary(grouping: errors, by: { $0.code.rawValue })
        return groups.keys.sorted().compactMap { key in
            guard let values = groups[key], let first = values.first else { return nil }
            let captured = capture(first, phase: phase, count: values.count)
            let delay = values.compactMap(\.retryAfterSeconds).filter { $0.isFinite && $0 >= 0 }.max()
            return Self(phase: captured.phase, domain: captured.domain, code: captured.code,
                retryAfter: delay, count: captured.count, retryable: captured.retryable, reasonCode: captured.reasonCode)
        }
    }
}

/// Bounded numeric/stable-code diagnostics. Callers never pass ledger or account strings.
struct SyncDiagnosticEvent: Codable, Equatable, Sendable {
    let event: String
    let at: Date
    let count: Int
    let milliseconds: Int?
}
