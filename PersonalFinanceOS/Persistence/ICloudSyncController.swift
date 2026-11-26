import CloudKit
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ICloudSyncController {
    enum Status: Equatable {
        case off, starting, enabled, unavailable, accountChanged, stopping, pendingRelationships, needsCategoryReview, retrying, oversizedRecords, error

        var description: String {
            switch self {
            case .off: "数据仅保存在本机。开启后，可通过您的私人 iCloud 在 Apple 设备间自动同步。"
            case .starting: "正在连接 iCloud，本机记账不受影响。"
            case .enabled: "iCloud 同步已开启。本机数据会正常保存，同步由系统安排。"
            case .oversizedRecords: "部分记录内容过大，暂时无法同步；本机内容已保留，其他记录将继续同步。"
            case .retrying: "iCloud 暂时不可用，系统将自动重试。本机记账不受影响。"
            case .unavailable: "当前无法访问 iCloud，本机数据仍会正常保存。"
            case .accountChanged: "Apple 账户已更改。请关闭后重新开启，以确认使用当前账户。本机账本保持完整。"
            case .stopping: "正在停止 iCloud 同步，本机数据将完整保留。"
            case .needsCategoryReview: "本机与 iCloud 的分类设置存在差异。请先审阅分类；本机记账和两端数据均已保留。"
            case .pendingRelationships: "部分同步修改存在关联问题，暂未写入本机。记账和本机数据不受影响。"
            case .error: "同步暂时无法继续，本机账本保持完整。请重试；若仍失败，请展开诊断与支持导出摘要。"
            }
        }
    }

    private(set) var isEnabled = ICloudSyncPreferences().isEnabled
    private(set) var status: Status = ICloudSyncPreferences().isEnabled ? .unavailable : .off
    private(set) var syncEvidence: PrivateCloudReplicaSession.SyncEvidence?
    private(set) var isSyncRequested = false
    private var confirmedContentRevision: UInt64?
    private var capturedContentRevision: UInt64?
    private(set) var historicalFailure: SyncFailure?
    private(set) var lastFailure: SyncFailure? {
        didSet { if let lastFailure { historicalFailure = lastFailure } }
    }

    struct DisplaySnapshot: Codable, Equatable, Sendable {
        enum Stage: String, Codable { case paused, editing, continuing, off, connecting, firstSync, preparing, waiting, uploading, receiving, applying, confirmed, requested, retrying, categoryReview, relationships, oversized, accountChanged, error }
        let stage: Stage
        let pendingChanges: Int
        let categoryDifferences: Int
        let lastUploadAt: Date?
        let lastAppliedAt: Date?
        let lastConfirmedAt: Date?
        let errorCodes: [Int]
        var engineAvailable = false
        var firstFetchCompleted = false
        var projectionReady = false
        var currentFetchApplied = false
        var pendingApplication = false
        var pendingDatabaseChanges = 0
        var failures: [SyncFailure] = []
        var environment = "unavailable"
        var waitReason: RequestPause?
        var historicalFailures: [SyncFailure] = []
        var completedRequestAt: Date?
        var inFlightCount = 0
        var batchCount = 0
        var batchPauseReason: String?
        var events: [SyncDiagnosticEvent] = []

        var redactedSummary: String {
            let issues = failures.map { "\($0.phase):\($0.domain).\($0.code)×\($0.count)" + ($0.retryAfter.map { " retryAfter=\($0)s" } ?? "") }.joined(separator: ";")
            let historical = lastConfirmedAt.map { $0.formatted(.iso8601) } ?? "none"
            return "stage=\(stage.rawValue) environment=\(environment) engine=\(engineAvailable) firstFetch=\(firstFetchCompleted) projection=\(projectionReady) applied=\(currentFetchApplied) pendingApply=\(pendingApplication) records=\(pendingChanges) database=\(pendingDatabaseChanges) confirmedNow=\(stage == .confirmed) historicalConfirmed=\(historical) inFlight=\(inFlightCount) batch=\(batchCount) batchPause=\(batchPauseReason ?? "none") wait=\(waitReason?.rawValue ?? "none") errors=[\(issues)] events=[\(events.suffix(12).map { "\($0.event):\($0.count):\($0.milliseconds ?? 0)ms" }.joined(separator: ";"))]"
        }

        var title: String {
            switch stage {
            case .paused: "同步已暂停，回到前台后继续"
            case .editing: "等待本机编辑完成"
            case .continuing: "等待继续同步"
            case .off: "仅本机保存"
            case .connecting: "正在连接 iCloud"
            case .firstSync: "正在等待首次同步"
            case .preparing: "正在准备本机变化"
            case .waiting: "等待同步，原因暂未确认"
            case .uploading: "正在上传变化"
            case .receiving: "正在接收变化"
            case .applying: "正在写入本机"
            case .confirmed: "本机已同步"
            case .requested: "正在请求同步"
            case .retrying: "暂时离线或等待重试"
            case .categoryReview: "需要处理分类差异"
            case .relationships: "正在等待关联数据"
            case .oversized: "部分记录过大，需处理"
            case .accountChanged: "需要确认当前账户"
            case .error: "同步遇到问题"
            }
        }
    }

    var displaySnapshot: DisplaySnapshot {
        let evidence = syncEvidence
        let stage: DisplaySnapshot.Stage
        switch status {
        case .off, .stopping: stage = .off
        case .starting: stage = .connecting
        case .accountChanged: stage = .accountChanged
        case .needsCategoryReview: stage = .categoryReview
        case .pendingRelationships: stage = .relationships
        case .oversizedRecords: stage = .oversized
        case .error: stage = .error
        case .unavailable, .retrying: stage = .retrying
        case .enabled:
            if evidence?.receiving == true { stage = .receiving }
            else if evidence?.uploading == true { stage = .uploading }
            else if requestPause == .background { stage = .paused }
            else if requestPause == .edits { stage = .editing }
            else if requestPause == .serviceRetry { stage = .retrying }
            else if requestPause == .applying { stage = .applying }
            else if requestPause == .noProgress { stage = .continuing }
            else if isSyncRequested { stage = .requested }
            else if evidence?.currentFetchSucceeded != true { stage = evidence?.initialFetchCompleted == true ? .waiting : .firstSync }
            else if evidence?.pendingApply == true || evidence?.appliedCurrentFetch != true { stage = .applying }
            else if capturedContentRevision != LedgerSaveRevision.shared.contentRevision { stage = .preparing }
            else if confirmedContentRevision == LedgerSaveRevision.shared.contentRevision, evidence?.canConfirm == true,
                    evidence?.revision == session?.evidenceRevision.token { stage = .confirmed }
            else if evidence?.errorCodes.isEmpty == false { stage = .retrying }
            else { stage = .waiting }
        }
        return DisplaySnapshot(stage: stage, pendingChanges: max(evidence?.pendingUploads ?? 0, (evidence?.queuedChanges ?? 0) - (evidence?.queuedDatabaseChanges ?? 0)),
            categoryDifferences: categoryReview?.conflicts.count ?? 0, lastUploadAt: evidence?.lastUploadAt,
            lastAppliedAt: evidence?.lastAppliedAt, lastConfirmedAt: evidence?.lastConfirmedAt,
            errorCodes: evidence?.errorCodes ?? [], engineAvailable: evidence?.connected ?? false,
            firstFetchCompleted: evidence?.initialFetchCompleted ?? false,
            projectionReady: evidence?.authorityReady ?? false, currentFetchApplied: evidence?.appliedCurrentFetch ?? false,
            pendingApplication: evidence?.pendingApply ?? false, pendingDatabaseChanges: evidence?.queuedDatabaseChanges ?? 0,
            failures: (evidence?.failures ?? []) + (lastFailure.map { [$0] } ?? []),
            environment: (Bundle.main.object(forInfoDictionaryKey: "PFCloudKitEnvironment") as? String)
                .flatMap { CloudReplicaLocation.Environment(rawValue: $0)?.rawValue } ?? "unavailable",
            waitReason: requestPause, historicalFailures: (evidence?.historicalFailures ?? []) + (historicalFailure.map { [$0] } ?? []),
            completedRequestAt: completedRequestAt, inFlightCount: evidence?.inFlightCount ?? 0,
            batchCount: evidence?.lastBatchCount ?? 0, batchPauseReason: evidence?.batchPauseReason,
            events: Array(((evidence?.events ?? []) + requestEvents).sorted { $0.at < $1.at }.suffix(48)))
    }

    func invalidateCurrentConfirmation() { confirmedContentRevision = nil }

    func refreshStatus() async {
        let operation = generation
        guard isEnabled, let session else { syncEvidence = nil; return }
        let evidence = await session.syncEvidence()
        guard generation == operation, isEnabled, self.session === session else { return }
        guard evidence.revision == session.evidenceRevision.token else { confirmedContentRevision = nil; return }
        let previous = displaySnapshot
        syncEvidence = evidence
        if !evidence.canConfirm { confirmedContentRevision = nil }
        if displaySnapshot != previous { LocalDiagnostics.shared.syncState(displaySnapshot) }
    }

    enum RequestPause: String, Codable, Sendable {
        case background, edits, fetch, applying, categoryReview, relationships, serviceRetry, attention, noProgress
    }
    private(set) var requestPause: RequestPause? {
        didSet {
            if requestPause != oldValue { traceRequest(requestPause.map { "paused_" + $0.rawValue } ?? "resumed") }
        }
    }
    private var requestEvents: [SyncDiagnosticEvent] = []
    private func traceRequest(_ event: String, started: Date? = nil) {
        requestEvents.append(.init(event: event, at: Date(), count: 0,
            milliseconds: started.map { Int(Date().timeIntervalSince($0) * 1000) }))
        if requestEvents.count > 24 { requestEvents.removeFirst(requestEvents.count - 24) }
    }
    private(set) var completedRequestAt: Date?
    @MainActor
    private final class ForegroundRequest {
        let id = UUID()
        let lifetime: UUID
        let context: ModelContext
        let changes: LedgerChangeCenter
        var needsFetch: Bool
        var target: PrivateCloudReplicaSession.UploadTarget?
        var sessionIdentity: ObjectIdentifier?
        var lastAttempt: SendAttempt?
        init(lifetime: UUID, context: ModelContext, changes: LedgerChangeCenter, needsFetch: Bool) {
            self.lifetime = lifetime; self.context = context; self.changes = changes; self.needsFetch = needsFetch
        }
    }
    private struct SendAttempt: Equatable {
        let graph: UInt64
        let fetch: UInt64
        let receipts: UInt64
        let pending: Int
        let recovery: UInt64
    }
    private var retryWake: (id: UUID, deadline: Date, task: Task<Void, Never>)?
    private var foregroundRequest: ForegroundRequest?
    private var requestWorker: (id: UUID, task: Task<Void, Never>)?
    private var requestWake: UInt64 = 0
    private var appliedProjection: (proof: PrivateCloudReplicaSession.ProjectionEvidence, content: UInt64)?
    private var appliedProjectionSerial: UInt64 = 0

    func syncNow(in context: ModelContext, changes: LedgerChangeCenter) async {
        guard isEnabled, status != .stopping else { return }
        // A duplicate joins the retained intent; it cannot reset a service's backoff.
        if foregroundRequest != nil {
            traceRequest("manual_coalesced")
            if requestWorker == nil, status == .error || status == .unavailable {
                await activate(forceRetry: true)
            }
            wakeSyncRequest()
            return
        }
        traceRequest("manual_requested")
        let request = ForegroundRequest(lifetime: manualRequestLifetime, context: context,
                                        changes: changes, needsFetch: true)
        foregroundRequest = request
        isSyncRequested = true
        await activate(forceRetry: true)
        await manualSyncActivated?()
        guard foregroundRequest === request, request.lifetime == manualRequestLifetime, isEnabled else { return }
        wakeSyncRequest()
        await requestWorker?.task.value
    }

    /// App lifecycle, saved/rolled-back edits and transport events all enter here.
    /// Reconstruct intent from the existing durable outbox after a cold start.
    func synchronize(in context: ModelContext, changes: LedgerChangeCenter) async {
        guard isEnabled, status != .stopping else { return }
        _ = await reconcileIfNeeded(in: context, changes: changes)
        guard isEnabled else { return }
        if isForeground, foregroundRequest == nil, let evidence = syncEvidence,
           evidence.pendingUploads > 0 || !evidence.currentFetchSucceeded {
            traceRequest("event_requested")
            foregroundRequest = ForegroundRequest(lifetime: manualRequestLifetime, context: context,
                changes: changes, needsFetch: !evidence.currentFetchSucceeded)
            isSyncRequested = true
        }
        wakeSyncRequest()
    }

    // Drains currently runnable work; a parked request keeps its intent after this returns.
    func waitForRequestWork() async {
        while let worker = requestWorker { await worker.task.value }
    }

    private func wakeSyncRequest() {
        requestWake &+= 1
        guard foregroundRequest != nil, requestWorker == nil, isEnabled else { return }
        guard isForeground else { requestPause = .background; return }
        let id = UUID()
        // Notifications may arrive in the SDK delegate context. Only this network
        // continuation is detached; delegate handling remains ordered on its actor.
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.runRequestWorker(workerID: id)
        }
        requestWorker = (id, task)
    }

    private func runRequestWorker(workerID: UUID) async {
        guard requestWorker?.id == workerID, let request = foregroundRequest else { return }
        await advanceSyncRequest(request, workerID: workerID)
    }

    private func owns(_ request: ForegroundRequest) -> Bool {
        foregroundRequest === request && request.lifetime == manualRequestLifetime && isEnabled && !Task.isCancelled
    }

    private func advanceSyncRequest(_ request: ForegroundRequest, workerID: UUID) async {
        var observedWake = requestWake
        defer {
            if requestWorker?.id == workerID {
                requestWorker = nil
                // A wake delivered while the worker was awaiting cannot be lost.
                if requestWake != observedWake { wakeSyncRequest() }
            }
        }
        while owns(request) {
            observedWake = requestWake
            guard isForeground else { requestPause = .background; return }
            guard let session else { requestPause = status == .retrying ? .serviceRetry : .attention; return }
            let operation = generation
            if let previous = request.sessionIdentity, previous != ObjectIdentifier(session) {
                request.target = nil
                request.lastAttempt = nil
                request.needsFetch = true
                traceRequest("request_rebound_session")
            }
            request.sessionIdentity = ObjectIdentifier(session)
            do {
                var progress = await session.requestProgress(target: request.target)
                guard owns(request), generation == operation, self.session === session else { return }
                if progress.retryDelay > 0 {
                    requestPause = .serviceRetry
                    scheduleRetryWake(request, deadline: progress.retryDeadline!, delay: progress.retryDelay, operation: operation)
                    return
                }
                guard progress.failures.isEmpty else {
                    let retryable = progress.failures.allSatisfy(\.retryable)
                    requestPause = retryable ? .serviceRetry : .attention
                    status = retryable ? .retrying : .error
                    await refreshStatus()
                    return
                }
                if request.needsFetch {
                    guard !progress.receiving else { requestPause = .fetch; return }
                    requestPause = .fetch
                    try await session.fetchNow()
                    guard owns(request), generation == operation, self.session === session else { return }
                    request.needsFetch = false
                }
                let outcome = await reconcileIfNeeded(in: request.context, changes: request.changes)
                guard owns(request), generation == operation, self.session === session else { return }
                switch outcome {
                case .ready:
                    if lastFailure?.retryable == true { lastFailure = nil }
                    break
                case .waitingForEdits: requestPause = .edits; return
                case .waitingForCategoryReview: requestPause = .categoryReview; return
                case .waitingForRelationships: requestPause = .relationships; return
                case .waitingForFetch:
                    requestPause = .applying
                    await beforeRequestPark?()
                    return
                case .failed, .superseded: requestPause = .attention; return
                }
                if request.target == nil { request.target = await session.makeUploadTarget() }
                progress = await session.requestProgress(target: request.target)
                guard owns(request), generation == operation, self.session === session else { return }
                if progress.targetComplete {
                    completedRequestAt = Date()
                    traceRequest("request_completed")
                    lastFailure = nil
                    foregroundRequest = nil
                    isSyncRequested = false
                    requestPause = nil
                    await refreshStatus()
                    return
                }
                guard progress.ready, !progress.receiving else { requestPause = .applying; return }
                guard progress.failures.isEmpty else { requestPause = .serviceRetry; return }
                if progress.retryDelay > 0 {
                    requestPause = .serviceRetry
                    scheduleRetryWake(request, deadline: progress.retryDeadline!, delay: progress.retryDelay, operation: operation)
                    return
                }
                guard !progress.uploading else { requestPause = nil; return }
                let attempt = SendAttempt(graph: progress.graphRevision, fetch: progress.fetchGeneration,
                    receipts: progress.receiptCount, pending: progress.pending, recovery: progress.recoveryGeneration)
                guard request.lastAttempt != attempt else { requestPause = .noProgress; return }
                request.lastAttempt = attempt
                requestPause = nil
                try await session.sendNow(target: request.target)
                guard owns(request), generation == operation, self.session === session else { return }
                // The SDK can request all batches in this one send. If a Fetch closed
                // its provider, the next iteration parks until projection evidence returns.
                await refreshStatus()
            } catch {
                guard owns(request), generation == operation, self.session === session else { return }
                if case let SyncCoordinationFailure.serviceBackoff(delay) = error {
                    requestPause = .serviceRetry
                    scheduleRetryWake(request, deadline: Date().addingTimeInterval(delay), delay: delay, operation: operation)
                    return
                }
                if (error as? ProtectedLedgerReplica.Failure) == .initialFetchRequired {
                    requestPause = .applying
                    return
                }
                confirmedContentRevision = nil
                lastFailure = SyncFailure.capture(error, phase: "manualSync")
                requestPause = lastFailure?.retryable == true ? .serviceRetry : .attention
                status = lastFailure?.retryable == true ? .retrying : .error
                await refreshStatus()
                return
            }
        }
    }

    private func scheduleRetryWake(_ request: ForegroundRequest, deadline: Date, delay: TimeInterval, operation: UUID) {
        if retryWake?.deadline == deadline { return }
        retryWake?.task.cancel()
        let id = UUID(), requestID = request.id
        let task = Task.detached { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.retryDeadlineReached(id: id, requestID: requestID, operation: operation)
        }
        retryWake = (id, deadline, task)
    }

    private func retryDeadlineReached(id: UUID, requestID: UUID, operation: UUID) {
        guard retryWake?.id == id else { return }
        retryWake = nil
        guard generation == operation, foregroundRequest?.id == requestID, isEnabled else { return }
        traceRequest("service_retry_deadline")
        wakeSyncRequest()
    }

    @discardableResult
    private func reconcileIfNeeded(in context: ModelContext, changes: LedgerChangeCenter) async -> ReconcileOutcome {
        let operation = generation
        let startingProjection = appliedProjectionSerial
        if let running = reconciliation, running.generation == operation { return await running.task.value }
        if let session {
            let transport = await session.status
            guard generation == operation, self.session === session, isEnabled else { return .superseded }
            if transport != .active && transport != .retrying {
                return await reconcile(in: context, changes: changes)
            }
            let evidence = await session.syncEvidence()
            guard generation == operation, self.session === session, isEnabled else { return .superseded }
            if evidence.receiving || !evidence.currentFetchSucceeded {
                await refreshStatus()
                return .waitingForFetch
            }
        }
        if let session, let applied = appliedProjection, !context.hasChanges,
           applied.content == LedgerSaveRevision.shared.contentRevision,
           await session.isCurrentProjection(applied.proof) {
            let evidence = await session.syncEvidence()
            if generation == operation, self.session === session, !context.hasChanges,
               applied.content == LedgerSaveRevision.shared.contentRevision, evidence.appliedCurrentFetch,
               evidence.currentFetchSucceeded, evidence.authorityReady, !evidence.pendingApply {
                if evidence.failures.isEmpty {
                    status = evidence.quarantined == 0 ? .enabled : .oversizedRecords
                    if lastFailure?.retryable == true { lastFailure = nil }
                }
                if evidence.canConfirm, confirmedContentRevision != applied.content {
                    do {
                        let confirmed = try await session.confirmLocalState(contentRevision: applied.content, projection: applied.proof)
                        if generation == operation, confirmed != nil,
                           applied.content == LedgerSaveRevision.shared.contentRevision { confirmedContentRevision = applied.content }
                    } catch {
                        lastFailure = SyncFailure.capture(error, phase: "confirmation")
                        status = .error
                        return .failed
                    }
                }
                await refreshStatus()
                return .ready
            }
        }
        // Another caller can finish a projection while the actor evidence reads
        // above suspend. Recheck that fresh proof instead of acting on a stale miss.
        if startingProjection != appliedProjectionSerial, generation == operation {
            return await reconcileIfNeeded(in: context, changes: changes)
        }
        return await reconcile(in: context, changes: changes)
    }

    private var session: PrivateCloudReplicaSession?
    private var identity = LedgerSyncIdentity()
    private var savedIdentity: LedgerSyncIdentity?
    private var identityURL: URL?
    private var generation = UUID()
    private var manualRequestLifetime = UUID()
    var manualSyncActivated: (() async -> Void)?
    var beforeRequestPark: (() async -> Void)?
    enum ReconcileOutcome: Equatable, Sendable {
        case ready, waitingForEdits, waitingForFetch, waitingForRelationships, waitingForCategoryReview
        case superseded, failed
    }
    private final class ReconcilePass {
        var needsAnotherPass = false
    }
    private var reconciliation: (id: UUID, generation: UUID, task: Task<ReconcileOutcome, Never>)?
    private(set) var reconciliationOutcome: ReconcileOutcome = .waitingForFetch
    enum ReconcileStage { case snapshot, prepared, projectionPrepared, beforeApply, beforeAcknowledgment, afterAcknowledgment, completed, retrying }
    // Deterministic interleavings exercise the production coordinator, without SDK scheduling.
    // Runs after releasing both locks, so a background writer can complete deterministically.
    var afterCheckedProjection: (() throws -> Void)?
    var reconcileCheckpoint: ((ReconcileStage) async throws -> Void)?

    struct CategoryReview: Identifiable, Sendable {
        let id: UUID
        let conflicts: [FirstJoinCategoryAdmission.Conflict]
        fileprivate let localWire: [String: Data]
        fileprivate let localRecords: [String: Data]
        fileprivate let replica: ProtectedLedgerReplica
        fileprivate let identity: LedgerSyncIdentity
        fileprivate let ledgerRevision: UInt64
        fileprivate let sessionToken: UInt64
        fileprivate let operation: UUID

        func displayPath(for value: NativeBackupPackage.CategoryPayload?, remote: Bool) -> String {
            guard let value else { return remote ? "云端没有此分类" : "本机已删除此默认分类" }
            let records = remote ? replica.livePayloads : localWire
            guard let parentID = value.parentID, let data = records["categories:\(parentID.uuidString)"],
                  let parent = try? JSONDecoder().decode(NativeBackupPackage.CategoryPayload.self, from: data) else {
                return value.name
            }
            return "\(parent.name) / \(value.name)"
        }
    }

    private(set) var categoryReview: CategoryReview?
    private var approvedCategoryReview: (wire: [String: Data], ledgerRevision: UInt64, sessionToken: UInt64, operation: UUID)?

    private let restoreAdmission = LedgerRestoreAdmission()

    init() {
        if !isEnabled { restoreAdmission.markStopped() }
    }

    struct CatalogAdmission {
        let readiness: CategoryCatalogPlanner.Readiness
        fileprivate let owner: ObjectIdentifier
        fileprivate let container: ObjectIdentifier
        fileprivate let operation: UUID
        fileprivate let sessionToken: UInt64?
    }

    func makeCatalogAdmission(for container: ModelContainer) async -> CatalogAdmission {
        let operation = generation
        var readiness: CategoryCatalogPlanner.Readiness = .pendingRemoteGraph
        var token: UInt64?
        if !isEnabled, session == nil, status != .stopping {
            readiness = .offline
        } else if let session, isEnabled, categoryReview == nil {
            let state = await session.reconcileState(pristine: false)
            if generation == operation, isEnabled, state.hasConfirmedProjection,
               state.status == .active || state.status == .retrying {
                // Confirmed receipt plus an applied complete replica, not a seed version.
                let startingIdentity = identity
                let valid = await Task.detached(priority: .utility) {
                    do {
                        var mapping = startingIdentity
                        let projected = try mapping.localPackage(from: state.replica)
                        _ = try ValidatedLedgerSnapshot(projected)
                        // Historical aliases can make raw livePayloads differ from the
                        // canonical, acknowledged projection without a pending change.
                        return try mapping.capture(projected) == state.replica.localBaseline
                    } catch { return false }
                }.value
                if valid, generation == operation, isEnabled, identity == startingIdentity {
                    readiness = .confirmedGraph
                    token = state.token
                }
            }
        }
        return CatalogAdmission(readiness: readiness, owner: ObjectIdentifier(self),
                                container: ObjectIdentifier(container), operation: operation,
                                sessionToken: token)
    }

    func withCatalogAdmission<T>(
        _ admission: CatalogAdmission, for container: ModelContainer, _ body: () throws -> T
    ) throws -> T {
        guard admission.owner == ObjectIdentifier(self), admission.container == ObjectIdentifier(container),
              admission.operation == generation else { throw ReconcileRevision.Failure.stalePlan }
        switch admission.readiness {
        case .pendingRemoteGraph:
            throw ReconcileRevision.Failure.stalePlan
        case .offline:
            guard !isEnabled, session == nil, status != .stopping else { throw ReconcileRevision.Failure.stalePlan }
            return try body()
        case .confirmedGraph:
            guard isEnabled, let session, let token = admission.sessionToken,
                  categoryReview == nil else { throw ReconcileRevision.Failure.stalePlan }
            return try session.reconcileRevision.withCurrentIfAvailable(token, body)
        }
    }

    func makeRestoreAdmission(for container: ModelContainer) throws -> LedgerRestoreAdmission.Ticket {
        guard !isEnabled, session == nil, status != .stopping else {
            throw LedgerRestoreAdmission.Failure.syncNotStopped
        }
        return try restoreAdmission.ticket(for: container)
    }

    /// This synchronous step is also exercised without starting CloudKit in tests.
    func prepareEnable() throws {
        guard status != .stopping else { throw LedgerRestoreAdmission.Failure.syncNotStopped }
        try LedgerSaveRevision.shared.withProjectionBoundary {
            restoreAdmission.invalidate()
            categoryReview = nil
            approvedCategoryReview = nil
            isEnabled = true
            ICloudSyncPreferences().isEnabled = true
        }
    }

    /// An already confirmed transport can also be driven with automatic scheduling disabled
    /// in deterministic bridge tests. Account verification remains in activate() in the app.
    init(confirmedSession: PrivateCloudReplicaSession, identity: LedgerSyncIdentity, identityURL: URL) {
        session = confirmedSession
        self.identity = identity
        self.identityURL = identityURL
        isEnabled = true
        status = .enabled
    }

    func enable() async {
        guard status != .stopping else { return }
        do { try prepareEnable() }
        catch { status = .error; return }
        await activate(allowAccountChange: true, forceRetry: true)
    }

    func disable() async {
        guard status != .stopping, isEnabled || session != nil || status != .off else { return }
        cancelActivationRetry()
        activationRetryCount = 0
        restoreAdmission.invalidate()
        categoryReview = nil
        approvedCategoryReview = nil
        if foregroundRequest != nil { traceRequest("request_cancelled_off") }
        retryWake?.task.cancel()
        retryWake = nil
        requestWorker?.task.cancel()
        requestWorker = nil
        foregroundRequest = nil
        isSyncRequested = false
        requestPause = nil
        appliedProjection = nil
        reconciliation?.task.cancel()
        reconciliation = nil
        generation = UUID()
        manualRequestLifetime = UUID()
        confirmedContentRevision = nil
        capturedContentRevision = nil
        syncEvidence = nil
        lastFailure = nil
        ICloudSyncPreferences().isEnabled = false
        status = .stopping
        let stopping = session
        session = nil
        await stopping?.stop()
        isEnabled = false
        status = .off
        restoreAdmission.markStopped()
    }

    struct VerifiedActivation {
        let environment: CloudReplicaLocation.Environment
        let account: String
        let root: URL
        var automaticallySync = true
        var operations: PrivateCloudReplicaSession.EngineOperations?
    }
    var activationSessionStarted: ((PrivateCloudReplicaSession) async -> Void)?
    // Test seam at the account-service boundary; all session, identity and admission logic stays real.
    var activationVerification: (() async throws -> VerifiedActivation)?
    var activationRetryWait: ((Double) async throws -> Void)?
    private var isForeground = false
    private(set) var activationRetryTask: Task<Void, Never>?
    private var activationRetryID = UUID()
    private var activationRetryCount = 0
    private let maximumActivationRetries = 3

    func setForeground(_ active: Bool) {
        guard active != isForeground else { return }
        isForeground = active
        cancelActivationRetry()
        activationRetryCount = 0
        if active { scheduleActivationRetry(); wakeSyncRequest() }
        else if foregroundRequest != nil { requestPause = .background }
    }

    private func cancelActivationRetry() {
        activationRetryID = UUID()
        activationRetryTask?.cancel()
        activationRetryTask = nil
    }

    private func scheduleActivationRetry() {
        guard isForeground, isEnabled, session == nil, status == .retrying,
              lastFailure?.phase == "activation", lastFailure?.retryable == true,
              activationRetryTask == nil else { return }
        guard activationRetryCount < maximumActivationRetries else { status = .error; return }
        let operation = generation, retry = UUID()
        activationRetryID = retry
        let delay = max(pow(2, Double(activationRetryCount + 1)), lastFailure?.retryAfter ?? 0)
        activationRetryCount += 1
        activationRetryTask = Task { [weak self] in
            // Do not keep the controller alive during the timer.
            let wait = self?.activationRetryWait
            do {
                if let wait { try await wait(delay) }
                else { try await Task.sleep(for: .seconds(delay)) }
            } catch { return }
            guard let self, !Task.isCancelled, self.activationRetryID == retry,
                  self.generation == operation, self.isForeground, self.isEnabled,
                  self.session == nil, self.status == .retrying else { return }
            self.activationRetryTask = nil
            await self.activate(automaticRecovery: true)
        }
    }
    static func requireAvailableAccount(_ status: CKAccountStatus) throws {
        switch status {
        case .available: return
        case .noAccount: throw CKError(.notAuthenticated)
        case .restricted: throw CKError(.permissionFailure)
        case .couldNotDetermine, .temporarilyUnavailable: throw CKError(.accountTemporarilyUnavailable)
        @unknown default: throw CocoaError(.coderInvalidValue)
        }
    }
    private func verifiedActivation() async throws -> VerifiedActivation {
        if let activationVerification { return try await activationVerification() }
        guard let value = Bundle.main.object(forInfoDictionaryKey: "PFCloudKitEnvironment") as? String,
              let environment = CloudReplicaLocation.Environment(rawValue: value) else {
            throw CocoaError(.coderInvalidValue)
        }
        let cloud = CKContainer(identifier: ModelContainerFactory.cloudContainerIdentifier)
        try Self.requireAvailableAccount(try await cloud.accountStatus())
        let account = try await cloud.userRecordID().recordName
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("PersonalFinanceOS/CloudReplica")
        return VerifiedActivation(environment: environment, account: account, root: root)
    }

    func activate(allowAccountChange: Bool = false, forceRetry: Bool = false, automaticRecovery: Bool = false) async {
        if forceRetry {
            cancelActivationRetry()
            activationRetryCount = 0
        } else if !automaticRecovery, activationRetryTask != nil { return }
        guard isEnabled, status != .starting, status != .stopping else { return }
        let previousGeneration = generation
        if let previous = session {
            let transport = await previous.status
            guard isEnabled, generation == previousGeneration, self.session === previous else { return }
            if transport == .active || transport == .retrying { return }
            if transport == .accountChanged, !allowAccountChange {
                foregroundRequest = nil; isSyncRequested = false; manualRequestLifetime = UUID()
                status = .accountChanged; return
            }
            await previous.stop()
            guard isEnabled, generation == previousGeneration, self.session === previous else { return }
            session = nil
        }
        if status == .accountChanged, !allowAccountChange { return }
        generation = UUID()
        confirmedContentRevision = nil
        capturedContentRevision = nil
        syncEvidence = nil
        let activation = generation
        let recovery = activationRetryID
        status = .starting
        do {
            let verified = try await verifiedActivation()
            guard isEnabled, generation == activation else { return }
            if automaticRecovery, (!isForeground || activationRetryID != recovery) {
                status = .retrying
                scheduleActivationRetry()
                return
            }
            let environment = verified.environment
            let account = verified.account
            let root = verified.root
            let accountKey = "icloudSyncConfirmedAccount." + environment.rawValue
            if let confirmed = UserDefaults.standard.string(forKey: accountKey),
               confirmed != account, !allowAccountChange {
                status = .accountChanged
                return
            }
            let location = CloudReplicaLocation(root: root, environment: environment, account: account)
            let mappingURL = location.identityURL
            if FileManager.default.fileExists(atPath: mappingURL.path) {
                identity = try JSONDecoder().decode(LedgerSyncIdentity.self, from: Data(contentsOf: mappingURL))
                savedIdentity = identity
            } else {
                identity = LedgerSyncIdentity()
                savedIdentity = nil
            }
            identityURL = mappingURL
            let created = try PrivateCloudReplicaSession(
                stateURL: location.stateURL, accountIdentifier: account, automaticallySync: verified.automaticallySync,
                operations: verified.operations
            )
            session = created
            try await created.start(verifiedAccountIdentifier: account)
            await activationSessionStarted?(created)
            guard isEnabled, generation == activation,
                  !automaticRecovery || (isForeground && activationRetryID == recovery) else {
                await created.stop()
                if generation == activation, session === created {
                    session = nil
                    status = .retrying
                    scheduleActivationRetry()
                }
                return
            }
            UserDefaults.standard.set(account, forKey: accountKey)
            lastFailure = nil
            activationRetryCount = 0
            status = .enabled
            if automaticRecovery { NotificationCenter.default.post(name: PrivateCloudReplicaSession.didChange, object: nil) }
        } catch {
            if generation == activation, isEnabled {
                lastFailure = SyncFailure.capture(error, phase: "activation")
                let failed = session
                session = nil
                await failed?.stop()
                guard generation == activation, isEnabled else { return }
                status = lastFailure?.retryable == true ? .retrying : .error
                scheduleActivationRetry()
            }
        }
    }

    /// All callers join the same actual projection, rather than interpreting an early
    /// return as completion. No ledger or replica lock crosses the shared task's awaits.
    @discardableResult
    func reconcile(in context: ModelContext, changes: LedgerChangeCenter) async -> ReconcileOutcome {
        guard isEnabled, let session else { return .superseded }
        if let running = reconciliation, running.generation == generation {
            return await running.task.value
        }
        let operation = generation
        let id = UUID()
        // This task only prepares/applies local data. Network follow-ups have their
        // own detached boundary and must never inherit a delegate notification context.
        let task = Task { @MainActor [self] in
            let pass = ReconcilePass()
            repeat {
                pass.needsAnotherPass = false
                guard !Task.isCancelled, isEnabled, generation == operation,
                      self.session === session else { return ReconcileOutcome.superseded }
                await reconcilePass(in: context, changes: changes, pass: pass)
                if pass.needsAnotherPass { try? await reconcileCheckpoint?(.retrying) }
            } while pass.needsAnotherPass && !context.hasChanges
            guard !Task.isCancelled, isEnabled, generation == operation,
                  self.session === session else { return ReconcileOutcome.superseded }
            await refreshStatus()
            if context.hasChanges { return ReconcileOutcome.waitingForEdits }
            switch status {
            case .needsCategoryReview: return ReconcileOutcome.waitingForCategoryReview
            case .pendingRelationships: return ReconcileOutcome.waitingForRelationships
            case .error: return ReconcileOutcome.failed
            case .off, .stopping, .accountChanged, .unavailable: return ReconcileOutcome.superseded
            default: break
            }
            let evidence = await session.syncEvidence()
            guard isEnabled, generation == operation, self.session === session else { return ReconcileOutcome.superseded }
            guard capturedContentRevision == LedgerSaveRevision.shared.contentRevision,
                  evidence.authorityReady, evidence.currentFetchSucceeded,
                  evidence.appliedCurrentFetch, !evidence.pendingApply else { return ReconcileOutcome.waitingForFetch }
            return ReconcileOutcome.ready
        }
        reconciliation = (id, operation, task)
        let result = await task.value
        if reconciliation?.id == id {
            reconciliation = nil
            reconciliationOutcome = result
        }
        return result
    }

    private func reconcilePass(in context: ModelContext, changes: LedgerChangeCenter, pass: ReconcilePass) async {
        guard isEnabled, let session else { return }
        let started = Date()
        defer { traceRequest("reconcile_returned", started: started) }
        let operation = generation
        do {
            let transportStatus = await session.status
            guard isEnabled, generation == operation else { return }
            switch transportStatus {
            case .accountChanged, .accountUnavailable:
                await session.stop()
                guard isEnabled, generation == operation else { return }
                self.session = nil
                manualRequestLifetime = UUID()
                foregroundRequest = nil
                isSyncRequested = false
                requestPause = nil
                syncEvidence = nil
                confirmedContentRevision = nil
                capturedContentRevision = nil
                status = transportStatus == .accountChanged ? .accountChanged : .unavailable
                return
            case .stopped: return
            case .needsAttention: status = .error
            case .retrying: status = .retrying
            case .active:
                if status == .retrying {
                    status = .enabled
                    if lastFailure?.retryable == true { lastFailure = nil }
                }
            }
            guard !context.hasChanges else { return }
            var revision = LedgerSaveRevision.shared.revision
            var local = try await LedgerSnapshotReader(modelContainer: context.container).capture()
            try await session.recoverProjection(
                committedID: LedgerSnapshotCodec.committedProjectionID(in: context)
            )
            let pristine = try isPristineBootstrap(local, in: context)
            var reconcileState = await session.reconcileState(pristine: pristine)
            try await reconcileCheckpoint?(.snapshot)
            switch reconcileState.status {
            case .active, .retrying: break
            case .accountChanged, .accountUnavailable:
                pass.needsAnotherPass = true
                return
            case .needsAttention:
                status = .error
                return
            case .stopped: return
            }
            let initialProjection = reconcileState.initialProjection
            if initialProjection == .waitingForFetch {
                if session.reconcileRevision.token != reconcileState.token { pass.needsAnotherPass = true }
                return
            }
            guard isEnabled, generation == operation else { return }
            let isFirstProjection = initialProjection == .adoptBootstrap
            let startingIdentity = identity
            let startingReplica = reconcileState.replica
            var prepared = try await Self.prepareLocal(
                local, identity: startingIdentity, replica: startingReplica, adoptBootstrap: isFirstProjection
            )
            try await reconcileCheckpoint?(.prepared)
            guard isEnabled, generation == operation else { return }
            guard revision == LedgerSaveRevision.shared.revision, !context.hasChanges else {
                pass.needsAnotherPass = true
                return
            }
            if !isFirstProjection, try preserveCatalogVersion(
                local: local, wire: prepared.wire, remote: startingReplica,
                in: context, session: session, token: reconcileState.token,
                expectedRevision: revision, changes: changes
            ) {
                revision = LedgerSaveRevision.shared.revision
                local = try await LedgerSnapshotReader(modelContainer: context.container).capture()
                prepared = try await Self.prepareLocal(
                    local, identity: startingIdentity, replica: startingReplica, adoptBootstrap: false
                )
                guard isEnabled, generation == operation else { return }
                guard revision == LedgerSaveRevision.shared.revision, !context.hasChanges else {
                    pass.needsAnotherPass = true
                    return
                }
            }
            if !reconcileState.hasConfirmedProjection, !isFirstProjection {
                let admissionWire = prepared.wire
                let admission = try await Task.detached(priority: .utility) {
                    try FirstJoinCategoryAdmission.evaluate(local: admissionWire, remote: startingReplica)
                }.value
                guard isEnabled, generation == operation else { return }
                guard revision == LedgerSaveRevision.shared.revision, !context.hasChanges else {
                    pass.needsAnotherPass = true
                    return
                }
                let approved = approvedCategoryReview.map {
                    $0.wire == prepared.wire && $0.ledgerRevision == revision &&
                    $0.sessionToken == reconcileState.token && $0.operation == operation
                } ?? false
                switch admission {
                case .waitingForGraph:
                    try session.reconcileRevision.withCurrent(reconcileState.token) {
                        categoryReview = nil
                        approvedCategoryReview = nil
                        status = .pendingRelationships
                    }
                    return
                case let .review(conflicts) where !approved:
                    try session.reconcileRevision.withCurrent(reconcileState.token) {
                        categoryReview = CategoryReview(
                            id: UUID(), conflicts: conflicts, localWire: prepared.wire,
                            localRecords: prepared.before, replica: startingReplica, identity: prepared.identity,
                            ledgerRevision: revision, sessionToken: reconcileState.token, operation: operation
                        )
                        approvedCategoryReview = nil
                        status = .needsCategoryReview
                    }
                    return
                case .ready, .review: break
                }
            }
            // An unused new-device bootstrap waits for the initial cloud graph before upload.
            if !isFirstProjection || reconcileState.replica.livePayloads.isEmpty {
                try session.reconcileRevision.withCurrent(reconcileState.token) {
                    identity = prepared.identity
                    try saveIdentity()
                }
                reconcileState = try await session.captureLocal(
                    prepared.wire, ifCurrent: reconcileState.token, pristine: pristine
                )
            }
            guard isEnabled, generation == operation else { return }
            let mapping = prepared.identity
            let incoming = reconcileState.replica
            let projection: (validated: ValidatedLedgerSnapshot, records: [String: Data], wire: [String: Data], identity: LedgerSyncIdentity)
            do {
                projection = try await Task.detached(priority: .utility) {
                    var projectedIdentity = mapping
                    let candidate = try projectedIdentity.localPackage(from: incoming)
                    let validated = try ValidatedLedgerSnapshot(candidate)

                    let records = try LedgerSnapshotCodec.records(candidate)
                    let wire = try projectedIdentity.capture(candidate)
                    return (validated: validated, records: records, wire: wire, identity: projectedIdentity)
                }.value
            } catch let error as NativeBackupError {
                guard isEnabled, generation == operation else { return }
                if case .invalidReference = error { status = .pendingRelationships } else { status = .error }
                return
            }
            guard isEnabled, generation == operation else { return }
            guard revision == LedgerSaveRevision.shared.revision, !context.hasChanges else {
                pass.needsAnotherPass = true
                return
            }
            try await reconcileCheckpoint?(.projectionPrepared)
            var applyToken = reconcileState.token
            var projectionID: UUID?
            if projection.records != prepared.before {
                let receipt = try await session.prepareProjection(projection.wire, ifCurrent: applyToken)
                applyToken = receipt.token
                projectionID = receipt.id
            }
            try await reconcileCheckpoint?(.beforeApply)
            guard isEnabled, generation == operation else { return }
            let appliedContentRevision = try LedgerSaveRevision.shared.withProjectionBoundary {
                try session.reconcileRevision.withCurrent(applyToken) {
                    guard revision == LedgerSaveRevision.shared.revision, !context.hasChanges else {
                        throw ReconcileRevision.Failure.stalePlan
                    }
                    // Persist aliases before their ledger projection can commit. Receipt recovery
                    // after a crash must translate that graph back to the same on-device UUIDs.
                    identity = projection.identity
                    try saveIdentity()
                    if projection.records != prepared.before {
                        let changedKeys = Set(projection.records.keys).union(prepared.before.keys).filter {
                            projection.records[$0] != prepared.before[$0]
                        }
                        try LedgerSnapshotCodec.apply(
                            projection.validated, in: context, changedKeys: Set(changedKeys), projectionID: projectionID, expectedRevision: revision
                        )
                        changes.recordMutation()
                    }
                }
                return LedgerSaveRevision.shared.contentRevision
            }
            try afterCheckedProjection?()
            try await reconcileCheckpoint?(.beforeAcknowledgment)
            let acknowledgment = try await session.acknowledgeLocalProjection(projection.wire,
                ifCurrent: applyToken, fetchGeneration: reconcileState.fetchGeneration, projectionID: projectionID)
            try await reconcileCheckpoint?(.afterAcknowledgment)
            guard generation == operation, isEnabled else { return }
            if let acknowledgment, appliedContentRevision == LedgerSaveRevision.shared.contentRevision {
                capturedContentRevision = appliedContentRevision
                appliedProjection = (acknowledgment, appliedContentRevision)
                appliedProjectionSerial &+= 1
                let confirmed = try await session.confirmLocalState(contentRevision: appliedContentRevision, projection: acknowledgment)
                guard generation == operation, isEnabled else { return }
                if confirmed != nil, appliedContentRevision == LedgerSaveRevision.shared.contentRevision {
                    confirmedContentRevision = appliedContentRevision
                } else {
                    confirmedContentRevision = nil
                    let currentProjection = await session.isCurrentProjection(acknowledgment)
                    guard generation == operation, isEnabled else { return }
                    if appliedContentRevision != LedgerSaveRevision.shared.contentRevision ||
                        !currentProjection { pass.needsAnotherPass = true }
                }
            } else { confirmedContentRevision = nil; pass.needsAnotherPass = true }
            if generation == operation {
                categoryReview = nil
                approvedCategoryReview = nil
            }
            let oversized = await session.oversizedRecords()
            if generation == operation, transportStatus == .active {
                status = oversized.isEmpty ? .enabled : .oversizedRecords
            }
            try await reconcileCheckpoint?(.completed)
        } catch ReconcileRevision.Failure.stalePlan {
            pass.needsAnotherPass = true
        } catch {
            if generation == operation {
                lastFailure = SyncFailure.capture(error, phase: "reconcile")
                status = .error
            }
        }
    }

    private nonisolated static func prepareLocal(
        _ local: NativeBackupPackage, identity: LedgerSyncIdentity,
        replica: ProtectedLedgerReplica, adoptBootstrap: Bool
    ) async throws -> (before: [String: Data], wire: [String: Data], identity: LedgerSyncIdentity) {
        try await Task.detached(priority: .utility) {
            _ = try ValidatedLedgerSnapshot(local)
            var mapping = identity
            try mapping.adoptCompatibleImportKeys(in: local, from: replica)
            if adoptBootstrap, let localAccount = local.accounts.first {
                let remoteDefault = try LedgerSyncIdentity.wirePackage(from: replica.livePayloads)
                    .accounts.first(where: \.isDefault)
                mapping.adoptBootstrapAccount(
                    localID: localAccount.id,
                    wireID: remoteDefault?.id ?? LedgerSyncIdentity.bootstrapAccountID
                )
            }
            return (try LedgerSnapshotCodec.records(local), try mapping.capture(local), mapping)
        }.value
    }

    /// The existing catalog marker is monotonic, but never authorizes missing nodes.
    /// Commit its maximum locally before ordinary full capture so the normal Lamport
    /// writer publishes it; do not forge a baseline or acknowledge an unapplied value.
    private func preserveCatalogVersion(
        local: NativeBackupPackage, wire: [String: Data], remote: ProtectedLedgerReplica,
        in context: ModelContext, session: PrivateCloudReplicaSession, token: UInt64,
        expectedRevision: UInt64, changes: LedgerChangeCenter
    ) throws -> Bool {
        guard let localMetadata = local.appMetadata.first else { return false }
        let remoteVersions = try remote.records.compactMap { key, record -> Int? in
            guard key.hasPrefix("appMetadata:"), let payload = record.payload else { return nil }
            return try JSONDecoder().decode(NativeBackupPackage.AppMetadataPayload.self, from: payload).defaultCategorySeedVersion
        }
        guard let remoteVersion = remoteVersions.max() else { return false }
        let localVersion = localMetadata.defaultCategorySeedVersion
        let metadataKeys = wire.keys.filter { $0.hasPrefix("appMetadata:") }
        let needsReassertion = remoteVersion < localVersion && !metadataKeys.isEmpty &&
            metadataKeys.allSatisfy { wire[$0] == remote.localBaseline[$0] }
        guard remoteVersion > localVersion || needsReassertion else { return false }
        return try session.reconcileRevision.withCurrentIfAvailable(token) {
            try LedgerSaveRevision.shared.withProjectionBoundary {
                guard expectedRevision == LedgerSaveRevision.shared.revision, !context.hasChanges else {
                    throw ReconcileRevision.Failure.stalePlan
                }
                let fresh = ModelContext(context.container)
                let metadata = try fresh.fetch(FetchDescriptor<AppMetadata>())
                guard metadata.count == 1, let value = metadata.first,
                      value.id == localMetadata.id, value.defaultCategorySeedVersion == localVersion else {
                    throw ReconcileRevision.Failure.stalePlan
                }
                value.defaultCategorySeedVersion = max(localVersion, remoteVersion)
                let now = Date()
                value.updatedAt = now == value.updatedAt ? now.addingTimeInterval(0.001) : now
                do { try fresh.save() }
                catch { fresh.rollbackNotifyingSync(); throw error }
                changes.recordMutation()
                return true
            }
        }
    }

    func resolveCategoryReview(
        id: UUID, choices: [String: FirstJoinCategoryAdmission.Choice],
        in context: ModelContext, changes: LedgerChangeCenter
    ) async throws {
        guard let review = categoryReview, review.id == id, let session,
              isEnabled, generation == review.operation else {
            throw FirstJoinCategoryAdmission.Failure.staleChoices
        }
        let planned = try await Task.detached(priority: .utility) {
            let desired = try FirstJoinCategoryAdmission.applying(
                choices, conflicts: review.conflicts, local: review.localWire, remote: review.replica
            )
            var mapping = review.identity
            let package = try mapping.localPackage(fromWireRecords: desired)
            let validated = try ValidatedLedgerSnapshot(package)

            return (validated: validated, records: try LedgerSnapshotCodec.records(package),
                    wire: try mapping.capture(package), identity: mapping)
        }.value
        do {
            try session.reconcileRevision.withCurrent(review.sessionToken) {
                try LedgerSaveRevision.shared.withProjectionBoundary {
                    guard isEnabled, generation == review.operation,
                          LedgerSaveRevision.shared.revision == review.ledgerRevision,
                          !context.hasChanges else { throw FirstJoinCategoryAdmission.Failure.staleChoices }
                    let changedKeys = Set(planned.records.keys).union(review.localRecords.keys).filter {
                        planned.records[$0] != review.localRecords[$0]
                    }
                    identity = planned.identity
                    try saveIdentity()
                    if !changedKeys.isEmpty {
                        // This is the user's explicit category edit, not a fabricated cloud
                        // acknowledgment. The normal reconcile still commits its receipt.
                        try LedgerSnapshotCodec.apply(
                            planned.validated, in: context, changedKeys: Set(changedKeys),
                            projectionID: nil, expectedRevision: review.ledgerRevision
                        )
                        changes.recordMutation()
                    }
                    approvedCategoryReview = (planned.wire, LedgerSaveRevision.shared.revision,
                                              review.sessionToken, review.operation)
                    categoryReview = nil
                }
            }
        } catch ReconcileRevision.Failure.stalePlan {
            throw FirstJoinCategoryAdmission.Failure.staleChoices
        }
        await synchronize(in: context, changes: changes)
    }

    private func isPristineBootstrap(_ package: NativeBackupPackage, in context: ModelContext) throws -> Bool {
        guard package.transactions.isEmpty, package.tags.isEmpty, package.merchants.isEmpty,
              package.importBatches.isEmpty, package.dailyReviews.isEmpty else { return false }
        return try DefaultFinanceDataService.isPristineBootstrap(
            accounts: context.fetch(FetchDescriptor<Account>()),
            categories: context.fetch(FetchDescriptor<Category>()),
            appMetadata: context.fetch(FetchDescriptor<AppMetadata>())
        )
    }

    private func saveIdentity() throws {
        guard let identityURL else { return }
        guard identity != savedIdentity else { return }
        try FileManager.default.createDirectory(
            at: identityURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(identity).write(
            to: identityURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        savedIdentity = identity
    }
}
