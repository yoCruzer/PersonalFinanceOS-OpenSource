import CloudKit
import CryptoKit
import Foundation

/// Owns only the optional transport and its protected replica, never the SwiftData ledger.
/// Start is intentionally explicit; constructing or loading this object performs no networking.
actor PrivateCloudReplicaSession: CKSyncEngineDelegate {
    static let zoneID = CKRecordZone.ID(zoneName: "ProtectedLedgerV1")
    static let recordType = "LedgerValueV1"
    static let didChange = Notification.Name("PrivateCloudReplicaSessionDidChange")

    struct Envelope: Codable, Sendable {
        let format: Int
        let accountIdentifier: String
        let key: String
        let record: ProtectedLedgerReplica.Record
    }

    struct State: Codable, Sendable {
        var replica: ProtectedLedgerReplica
        var engineState: CKSyncEngine.State.Serialization?
        var systemFields: [String: Data] = [:]
        var uploadedRevisions: [String: ProtectedLedgerReplica.Revision] = [:]
        var pendingProjection: PendingProjection?
        // Optional for files written by the original candidate. Never stored in ledger identities.
        var initialProjectionCompleted: Bool?
        var initialFetchCompleted: Bool?
        var oversizedRecords: [String: OversizedRecord]?
        var lastConfirmedAt: Date?
    }

    struct OversizedRecord: Codable, Equatable, Sendable {
        let revision: ProtectedLedgerReplica.Revision
        let encodedBytes: Int
    }

    // Leave headroom for CKRecord/system fields and request framing; never truncate payloads.
    static let maximumEnvelopeBytes = 900_000
    static let maximumBatchBytes = 1_500_000
    private var batchRecordLimit = 100
    private var lastBatchRecordCount = 0
    private var diagnosticEvents: [SyncDiagnosticEvent] = []
    private var historicalFailures: [SyncFailure] = []
    private func trace(_ event: String, count: Int = 0, started: Date? = nil) {
        diagnosticEvents.append(.init(event: event, at: Date(), count: count,
            milliseconds: started.map { Int(Date().timeIntervalSince($0) * 1000) }))
        if diagnosticEvents.count > 48 { diagnosticEvents.removeFirst(diagnosticEvents.count - 48) }
    }

    func oversizedRecords() -> [String: OversizedRecord] { state.oversizedRecords ?? [:] }

    struct PendingProjection: Codable, Sendable {
        let id: UUID
        let snapshot: [String: Data]
    }

    enum Status: Equatable, Sendable {
        case stopped
        case active
        case retrying
        case accountUnavailable
        case accountChanged
        case needsAttention
    }

    private(set) var lastPersistenceDuration: TimeInterval = 0
    private let stateURL: URL
    private let now: @Sendable () -> Date
    private var serviceRetryUntil: Date?
    private var recoveryGeneration: UInt64 = 0
    nonisolated let reconcileRevision = ReconcileRevision()
    nonisolated let evidenceRevision = ReconcileRevision()
    private var state: State {
        willSet { reconcileRevision.beginMutation(); evidenceRevision.beginMutation() }
        didSet {
            if state.replica.records != oldValue.replica.records {
                graphRevision &+= 1
                appliedCurrentFetch = false
            }
            evidenceRevision.endMutation(changed: state.replica != oldValue.replica ||
                state.pendingProjection?.id != oldValue.pendingProjection?.id ||
                state.uploadedRevisions != oldValue.uploadedRevisions ||
                state.oversizedRecords != oldValue.oversizedRecords || state.lastConfirmedAt != oldValue.lastConfirmedAt)
            reconcileRevision.endMutation(changed: state.replica != oldValue.replica ||
                state.initialFetchCompleted != oldValue.initialFetchCompleted ||
                state.initialProjectionCompleted != oldValue.initialProjectionCompleted ||
                state.pendingProjection?.id != oldValue.pendingProjection?.id)
        }
    }
    private var recordNamesByKey: [String: String] = [:]
    private var keysByRecordName: [String: String] = [:]
    private(set) var engine: CKSyncEngine? {
        willSet { reconcileRevision.beginMutation(); evidenceRevision.beginMutation() }
        didSet { reconcileRevision.endMutation(changed: engine !== oldValue); evidenceRevision.endMutation(changed: engine !== oldValue) }
    }
    private let automaticallySync: Bool
    /// Injecting operations disables SDK automatic networking, while still exercising
    /// the production follow-up scheduler and real engine identities in offline tests.
    struct EngineOperations: Sendable {
        var fetchChanges: @Sendable (CKSyncEngine) async throws -> Void
        var cancelOperations: @Sendable (CKSyncEngine) async -> Void
        var sendChanges: @Sendable (CKSyncEngine, CKSyncEngine.SendChangesOptions) async throws -> Void = { try await $0.sendChanges($1) }

        static let live = EngineOperations(
            fetchChanges: { try await $0.fetchChanges() },
            cancelOperations: { await $0.cancelOperations() }
        )
    }
    private let operations: EngineOperations
    private let usesSDKAutomaticSync: Bool
    private var stoppingTask: Task<Void, Never>?
    private var stoppingID: UUID?
    private(set) var status: Status = .stopped {
        willSet { reconcileRevision.beginMutation(); evidenceRevision.beginMutation() }
        didSet { reconcileRevision.endMutation(changed: status != oldValue); evidenceRevision.endMutation(changed: status != oldValue) }
    }
    private(set) var hasCompletedFetch = false {
        willSet { reconcileRevision.beginMutation() }
        didSet { reconcileRevision.endMutation(changed: hasCompletedFetch != oldValue) }
    }
    // Per activation: restored engine outbox cannot bypass the current SwiftData projection.
    private var localAuthorityReady = false
    private var fetchFailed = false
    private var zoneAvailable = false {
        willSet { evidenceRevision.beginMutation() }
        didSet { evidenceRevision.endMutation(changed: zoneAvailable != oldValue) }
    }
    private(set) var initializationFetch: Task<Void, Never>?

    enum OperationPhase: String, Codable, Sendable { case upload, databaseUpload, download, databaseDownload }
    struct SyncEvidence: Codable, Equatable, Sendable {
        let revision: UInt64
        let connected: Bool
        let uploading: Bool
        let receiving: Bool
        let currentFetchSucceeded: Bool
        let appliedCurrentFetch: Bool
        let authorityReady: Bool
        let pendingUploads: Int
        let pendingApply: Bool
        let queuedChanges: Int
        let quarantined: Int
        let errorCodes: [Int]
        let lastUploadAt: Date?
        let lastAppliedAt: Date?
        let lastConfirmedAt: Date?
        var queuedDatabaseChanges: Int = 0
        var zoneReady: Bool = false
        var failures: [SyncFailure] = []
        var inFlightCount: Int = 0
        var lastBatchCount: Int = 0
        var batchPauseReason: String? = nil
        var events: [SyncDiagnosticEvent] = []
        var historicalFailures: [SyncFailure] = []
        var initialFetchCompleted = false

        var canConfirm: Bool {
            connected && zoneReady && currentFetchSucceeded && appliedCurrentFetch && authorityReady &&
                !uploading && !receiving && pendingUploads == 0 && !pendingApply &&
                queuedChanges == 0 && quarantined == 0 && inFlightCount == 0 && errorCodes.isEmpty && failures.isEmpty
        }
    }
    private var uploading: Bool = false {
        willSet { evidenceRevision.beginMutation() }
        didSet { evidenceRevision.endMutation(changed: uploading != oldValue) }
    }
    private var receiving: Bool = false {
        willSet { evidenceRevision.beginMutation() }
        didSet { evidenceRevision.endMutation(changed: receiving != oldValue) }
    }
    private var currentFetchSucceeded: Bool = false {
        willSet { evidenceRevision.beginMutation() }
        didSet { evidenceRevision.endMutation(changed: currentFetchSucceeded != oldValue) }
    }
    private var appliedCurrentFetch: Bool = false {
        willSet { evidenceRevision.beginMutation() }
        didSet { evidenceRevision.endMutation(changed: appliedCurrentFetch != oldValue) }
    }
    private var pendingUploadCount: Int = 0 {
        willSet { evidenceRevision.beginMutation() }
        didSet { evidenceRevision.endMutation(changed: pendingUploadCount != oldValue) }
    }
    private var failures: [OperationPhase: [SyncFailure]] = [:] {
        willSet { evidenceRevision.beginMutation() }
        didSet { evidenceRevision.endMutation(changed: failures != oldValue) }
    }
    private var lastUploadAt: Date?
    private var lastAppliedAt: Date?
    private var fetchGeneration: UInt64 = 0
    private var graphRevision: UInt64 = 0
    private var projectionActivation = UUID()

    /// In-memory proof returned by a current commit receipt; never restored across activations.
    struct ProjectionEvidence: Sendable {
        fileprivate let graphRevision: UInt64
        fileprivate let fetchGeneration: UInt64
        fileprivate let activation: UUID
    }

    func isCurrentProjection(_ projection: ProjectionEvidence) -> Bool {
        projection.graphRevision == graphRevision && projection.fetchGeneration == fetchGeneration &&
            projection.activation == projectionActivation
    }

    /// Reads cached transport evidence; never queries the authoritative ledger.
    func syncEvidence() -> SyncEvidence {
        SyncEvidence(revision: evidenceRevision.token, connected: engine != nil && (status == .active || status == .retrying), uploading: uploading, receiving: receiving,
            currentFetchSucceeded: currentFetchSucceeded, appliedCurrentFetch: appliedCurrentFetch,
            authorityReady: localAuthorityReady, pendingUploads: pendingUploadCount,
            pendingApply: state.pendingProjection != nil,
            queuedChanges: (engine?.state.pendingRecordZoneChanges.count ?? 0) + (engine?.state.pendingDatabaseChanges.count ?? 0),
            quarantined: state.oversizedRecords?.count ?? 0, errorCodes: failures.values.flatMap { $0 }.filter { $0.domain == "CloudKit" }.map(\.code).sorted(),
            lastUploadAt: lastUploadAt, lastAppliedAt: lastAppliedAt, lastConfirmedAt: state.lastConfirmedAt,
            queuedDatabaseChanges: engine?.state.pendingDatabaseChanges.count ?? 0,
            zoneReady: zoneAvailable, failures: failures.keys.sorted { $0.rawValue < $1.rawValue }.flatMap { failures[$0] ?? [] },
            inFlightCount: inFlight.count, lastBatchCount: lastBatchRecordCount, batchPauseReason: batchPauseReason,
            events: diagnosticEvents, historicalFailures: historicalFailures, initialFetchCompleted: hasCompletedFetch)
    }

    func confirmLocalState(contentRevision: UInt64, projection: ProjectionEvidence) throws -> Date? {
        guard isCurrentProjection(projection), syncEvidence().canConfirm else { return nil }
        return try LedgerSaveRevision.shared.withProjectionBoundary {
            guard LedgerSaveRevision.shared.contentRevision == contentRevision else { return nil }
            let date = Date()
            var next = state
            next.lastConfirmedAt = date
            try persist(next)
            state = next
            return date
        }
    }

    func fetchNow() async throws {
        let started = Date()
        defer { trace("fetch_returned", started: started) }
        guard let engine else { throw ProtectedLedgerReplica.Failure.initialFetchRequired }
        do {
            // At most two rounds. Only initialization can send before the first fetch;
            // the record provider remains closed until a current projection is committed.
            for attempt in 0..<2 {
                if !zoneAvailable { try await operations.sendChanges(engine, .init()) }
                guard self.engine === engine else { throw ProtectedLedgerReplica.Failure.initialFetchRequired }
                do { try await operations.fetchChanges(engine) }
                catch let error as CKError where error.code == .zoneNotFound && attempt == 0 {
                    recordOperationResult(errors: [error], syncEngine: engine, phase: .download)
                    continue
                }
                guard self.engine === engine else { throw ProtectedLedgerReplica.Failure.initialFetchRequired }
                if zoneAvailable || attempt == 1 { return }
                guard failures[.download]?.contains(where: { $0.code == CKError.Code.zoneNotFound.rawValue }) == true else { return }
            }
        } catch {
            guard self.engine === engine else { throw error }
            if let ck = error as? CKError { recordOperationResult(errors: [ck], syncEngine: engine, phase: .download) }
            else {
                failures[.download] = [SyncFailure.capture(error, phase: "download")]
                currentFetchSucceeded = false
                appliedCurrentFetch = false
                pauseForAccountChange(engine, status: .needsAttention)
            }
            throw error
        }
    }

    struct UploadTarget: Sendable {
        fileprivate let activation: UUID
        fileprivate let revisions: [String: ProtectedLedgerReplica.Revision]
        var count: Int { revisions.count }
    }
    struct RequestProgress: Sendable {
        let ready: Bool
        let receiving: Bool
        let uploading: Bool
        let pending: Int
        let inFlight: Int
        let receiptCount: UInt64
        let graphRevision: UInt64
        let fetchGeneration: UInt64
        let failures: [SyncFailure]
        let targetRemaining: Int?
        let targetComplete: Bool
        let retryDeadline: Date?
        let retryDelay: TimeInterval
        let recoveryGeneration: UInt64
    }
    private var batchPauseReason: String? {
        didSet { if let batchPauseReason { trace("batch_nil_" + batchPauseReason, count: pendingUploadCount) } }
    }
    private var inFlight: [String: ProtectedLedgerReplica.Revision] = [:]
    private var receiptCount: UInt64 = 0

    func makeUploadTarget() -> UploadTarget {
        UploadTarget(activation: projectionActivation, revisions: state.replica.records.mapValues(\.revision))
    }

    func requestProgress(target: UploadTarget?) -> RequestProgress {
        let evidence = syncEvidence()
        let ready = evidence.connected && evidence.zoneReady && evidence.currentFetchSucceeded &&
            evidence.appliedCurrentFetch && evidence.authorityReady && !evidence.pendingApply
        let remaining = target.map { target in
            target.revisions.filter { key, revision in
                guard let name = recordNamesByKey[key], let uploaded = state.uploadedRevisions[name] else { return true }
                // A later server-confirmed revision supersedes the frozen target. This
                // never acknowledges the newest local edit from an older receipt.
                return uploaded < revision
            }.count
        }
        return RequestProgress(ready: ready, receiving: receiving, uploading: uploading,
            pending: pendingUploadCount, inFlight: inFlight.count, receiptCount: receiptCount,
            graphRevision: graphRevision, fetchGeneration: fetchGeneration, failures: evidence.failures, targetRemaining: remaining,
            targetComplete: target?.activation == projectionActivation && remaining == 0 &&
                ready && !uploading && !receiving && inFlight.isEmpty && evidence.failures.isEmpty && evidence.quarantined == 0,
            retryDeadline: serviceRetryUntil, retryDelay: max(0, serviceRetryUntil?.timeIntervalSince(now()) ?? 0),
            recoveryGeneration: recoveryGeneration)
    }

    private var activeSendTarget: UploadTarget?
    func sendNow(target: UploadTarget? = nil) async throws {
        let started = Date()
        defer { trace("send_returned", count: pendingUploadCount, started: started) }
        guard let engine, zoneAvailable, currentFetchSucceeded, appliedCurrentFetch, localAuthorityReady else { throw ProtectedLedgerReplica.Failure.initialFetchRequired }
        if let until = serviceRetryUntil, now() < until {
            throw SyncCoordinationFailure.serviceBackoff(until.timeIntervalSince(now()))
        }
        if let target, target.activation != projectionActivation { throw ProtectedLedgerReplica.Failure.initialFetchRequired }
        activeSendTarget = target
        defer { activeSendTarget = nil }
        let options: CKSyncEngine.SendChangesOptions
        if let target {
            options = .init(scope: .recordIDs(target.revisions.keys.map {
                CKRecord.ID(recordName: Self.recordName(for: $0), zoneID: Self.zoneID)
            }))
        } else { options = .init() }
        do { try await operations.sendChanges(engine, options) }
        catch {
            if self.engine === engine, let ck = error as? CKError {
                recordOperationResult(errors: [ck], syncEngine: engine, phase: .upload)
            }
            throw error
        }
    }

    /// The same durable acknowledgment used by the SDK event and deterministic tests.
    func recordSavedRecords(_ records: [CKRecord], syncEngine: CKSyncEngine) throws {
        guard engine === syncEngine else { return }
        var next = state
        for record in records { try rememberServerRecord(record, in: &next) }
        try persist(next)
        state = next
        for record in records {
            let envelope = try decode(record)
            if inFlight[record.recordID.recordName] == envelope.record.revision {
                inFlight.removeValue(forKey: record.recordID.recordName)
                receiptCount &+= 1
            }
        }
        if !records.isEmpty { lastUploadAt = Date() }
        enqueueUnsentRecords()
        trace("upload_receipts_persisted", count: records.count)
    }

    init(stateURL: URL, accountIdentifier: String, automaticallySync: Bool = true,
         operations: EngineOperations? = nil, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.stateURL = stateURL
        self.now = now
        self.automaticallySync = automaticallySync
        self.operations = operations ?? .live
        self.usesSDKAutomaticSync = automaticallySync && operations == nil
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let loaded = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
            guard loaded.replica.accountIdentifier == accountIdentifier else {
                throw ProtectedLedgerReplica.Failure.differentAccount
            }
            guard loaded.replica.format == ProtectedLedgerReplica.currentFormat else {
                throw ProtectedLedgerReplica.Failure.unsupportedFormat
            }
            state = loaded
            if state.initialProjectionCompleted == nil {
                state.initialProjectionCompleted = !state.replica.localBaseline.isEmpty
            }
            state.replica.beginWritingSession()
        } else {
            state = State(replica: .init(accountIdentifier: accountIdentifier), initialProjectionCompleted: false)
        }
        hasCompletedFetch = state.initialFetchCompleted == true
        for key in state.replica.records.keys {
            let name = Self.recordName(for: key)
            recordNamesByKey[key] = name
            keysByRecordName[name] = key
        }
    }

    func snapshot() -> ProtectedLedgerReplica { state.replica }

    struct ReconcileState: Sendable {
        let replica: ProtectedLedgerReplica
        let initialProjection: InitialProjection
        let hasConfirmedProjection: Bool
        let status: Status
        let token: UInt64
        let fetchGeneration: UInt64
    }

    func reconcileState(pristine: Bool) -> ReconcileState {
        ReconcileState(replica: state.replica, initialProjection: initialProjection(pristine: pristine),
                       hasConfirmedProjection: state.initialProjectionCompleted ?? !state.replica.localBaseline.isEmpty,
                       status: status, token: reconcileRevision.token, fetchGeneration: fetchGeneration)
    }

    func captureLocal(_ snapshot: [String: Data], ifCurrent token: UInt64, pristine: Bool) throws -> ReconcileState {
        try reconcileRevision.withCurrent(token) {
            try captureLocal(snapshot)
            return reconcileState(pristine: pristine)
        }
    }

    private func markCurrentFetchApplied() {
        if currentFetchSucceeded {
            appliedCurrentFetch = true
            lastAppliedAt = Date()
        }
    }

    func prepareProjection(_ snapshot: [String: Data], ifCurrent token: UInt64) throws -> (id: UUID, token: UInt64) {
        try reconcileRevision.withCurrent(token) {
            let id = try prepareProjection(snapshot)
            return (id, reconcileRevision.token)
        }
    }

    enum InitialProjection: Equatable, Sendable {
        case waitingForFetch, adoptBootstrap, established
    }

    func initialProjection(pristine: Bool) -> InitialProjection {
        // A baseline in a pre-fix replica is evidence from this transport only.
        let completed = state.initialProjectionCompleted ?? !state.replica.localBaseline.isEmpty
        guard !completed else { return .established }
        guard hasCompletedFetch else { return .waitingForFetch }
        return pristine ? .adoptBootstrap : .established
    }

    func captureLocal(_ snapshot: [String: Data]) throws {
        guard initialProjection(pristine: false) != .waitingForFetch else {
            throw ProtectedLedgerReplica.Failure.initialFetchRequired
        }
        var next = state
        try next.replica.captureLocal(snapshot)
        next.oversizedRecords = next.oversizedRecords?.filter { next.replica.records[$0.key]?.revision == $0.value.revision }
        guard next.replica.clock != state.replica.clock else { return }
        try persist(next)
        state = next
        for key in state.replica.records.keys where recordNamesByKey[key] == nil {
            rememberKey(key)
        }
        enqueueUnsentRecords()
    }

    /// The receipt always records what SwiftData committed, even if a newer graph arrived.
    /// Only the exact prepared graph and completed fetch may endorse application evidence.
    @discardableResult
    func acknowledgeLocalProjection(_ snapshot: [String: Data], ifCurrent token: UInt64,
                                    fetchGeneration: UInt64, projectionID: UUID?) throws -> ProjectionEvidence? {
        guard initialProjection(pristine: false) != .waitingForFetch else {
            throw ProtectedLedgerReplica.Failure.initialFetchRequired
        }
        let isCurrent = (reconcileRevision.token == token) && self.fetchGeneration == fetchGeneration
        let ownsPending = state.pendingProjection?.id == projectionID
        if state.replica.localBaseline != snapshot || (ownsPending && state.pendingProjection != nil) ||
            state.initialProjectionCompleted != true {
            var next = state
            next.replica.acknowledgeLocalProjection(snapshot)
            if ownsPending { next.pendingProjection = nil }
            next.initialProjectionCompleted = true
            try persist(next)
            state = next
        }
        localAuthorityReady = true
        if isCurrent { markCurrentFetchApplied() }
        else { appliedCurrentFetch = false }
        enqueueUnsentRecords()
        return isCurrent ? ProjectionEvidence(graphRevision: graphRevision,
            fetchGeneration: fetchGeneration, activation: projectionActivation) : nil
    }

    func prepareProjection(_ snapshot: [String: Data]) throws -> UUID {
        let projection = PendingProjection(id: UUID(), snapshot: snapshot)
        var next = state
        next.pendingProjection = projection
        try persist(next)
        state = next
        return projection.id
    }

    /// The SwiftData receipt distinguishes a committed import from an interrupted attempt.
    /// Subsequent user edits are then compared with the correct baseline, even after a crash.
    func recoverProjection(committedID: UUID?) throws {
        guard let projection = state.pendingProjection else { return }
        var next = state
        if projection.id == committedID {
            next.replica.acknowledgeLocalProjection(projection.snapshot)
            next.initialProjectionCompleted = true
        }
        next.pendingProjection = nil
        try persist(next)
        state = next
    }

    /// The caller must first verify CKContainer.userRecordID against the confirmed account.
    func start(verifiedAccountIdentifier: String) throws {
        guard verifiedAccountIdentifier == state.replica.accountIdentifier else {
            throw ProtectedLedgerReplica.Failure.differentAccount
        }
        guard engine == nil else { return }
        guard stoppingTask == nil else { throw ProtectedLedgerReplica.Failure.malformedRecord }
        try persist(state)
        var configuration = Self.configuration(stateSerialization: state.engineState, delegate: self)
        configuration.automaticallySync = usesSDKAutomaticSync
        let created = CKSyncEngine(configuration)
        hasCompletedFetch = state.initialFetchCompleted == true
        fetchFailed = false
        zoneAvailable = false
        projectionActivation = UUID()
        localAuthorityReady = false
        uploading = false
        receiving = false
        currentFetchSucceeded = false
        appliedCurrentFetch = false
        failures = [:]
        lastUploadAt = nil
        lastAppliedAt = nil
        engine = created
        status = .active
        created.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        enqueueUnsentRecords()
    }

    static func configuration(
        stateSerialization: CKSyncEngine.State.Serialization?, delegate: any CKSyncEngineDelegate
    ) -> CKSyncEngine.Configuration {
        var configuration = CKSyncEngine.Configuration(
            database: CKContainer(identifier: ModelContainerFactory.cloudContainerIdentifier)
                .privateCloudDatabase,
            stateSerialization: stateSerialization,
            delegate: delegate
        )
        configuration.automaticallySync = true
        return configuration
    }

    /// Invalidate callbacks before requesting cancellation. Apple permits in-flight completion
    /// even after cancelOperations returns; identity guards, not network quiescence, protect OFF.
    func stop() async {
        let stopping = engine
        engine = nil
        inFlight.removeAll()
        localAuthorityReady = false
        status = .stopped
        initializationFetch?.cancel()
        initializationFetch = nil
        if let stopping { scheduleCancellation(stopping) }
        let id = stoppingID
        await stoppingTask?.value
        // Concurrent stop callers must not clear a later activation's cancellation.
        if stoppingID == id {
            stoppingTask = nil
            stoppingID = nil
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard engine === syncEngine else { return }
        let previous = state
        do {
            switch event {
            case .willFetchChanges:
                recordFetchStarted(syncEngine: syncEngine)
            case .didFetchChanges:
                try finishFetchRound(syncEngine: syncEngine)
            case .willSendChanges:
                recordSendActivity(uploading: true, syncEngine: syncEngine)
            case .didSendChanges:
                recordSendActivity(uploading: false, syncEngine: syncEngine)
            case let .stateUpdate(update):
                var next = state
                next.engineState = update.stateSerialization
                try persist(next)
                state = next
            case let .accountChange(change):
                recordAccountChange(change.changeType, syncEngine: syncEngine)
            case let .fetchedRecordZoneChanges(changes):
                try receiveRemoteRecords(changes.modifications.map(\.record), syncEngine: syncEngine)
                // Server record/zone disappearance is not a user ledger deletion. Re-publish
                // protected values if necessary, retaining explicit tombstones as values too.
                for deletion in changes.deletions where deletion.recordID.zoneID == Self.zoneID {
                    state.systemFields.removeValue(forKey: deletion.recordID.recordName)
                    state.uploadedRevisions.removeValue(forKey: deletion.recordID.recordName)
                }
                try persist(state)
                enqueueUnsentRecords()
            case let .sentRecordZoneChanges(changes):
                try recordSentRecords(changes.savedRecords,
                    failedSaves: changes.failedRecordSaves.map { ($0.record, $0.error) }, syncEngine: syncEngine)
            case let .fetchedDatabaseChanges(changes):
                // A successful empty database fetch also covers a brand-new cloud zone.
                recordOperationResult(errors: [], syncEngine: syncEngine, phase: .databaseDownload)
                if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                    try recoverMissingZone(syncEngine: syncEngine)
                }
            case let .didFetchRecordZoneChanges(result):
                if result.zoneID == Self.zoneID {
                    recordZoneFetchResult(error: result.error, syncEngine: syncEngine)
                }
            case let .sentDatabaseChanges(result):
                recordDatabaseSendResult(savedZoneIDs: result.savedZones.map(\.zoneID),
                    errors: result.failedZoneSaves.map(\.error) + Array(result.failedZoneDeletes.values), syncEngine: syncEngine)
            default:
                break
            }
        } catch {
            // A failed durable write must not be followed by a persisted advanced fetch token.
            // Stop this session; a fresh start can replay from the last valid state file.
            state = previous
            failures[.databaseDownload] = [SyncFailure.capture(error, phase: "persistence")]
            pauseForAccountChange(syncEngine, status: .needsAttention)
        }
    }

    func recordSendActivity(uploading: Bool, syncEngine: CKSyncEngine) {
        guard engine === syncEngine else { return }
        self.uploading = uploading
        if !uploading { inFlight.removeAll(); enqueueUnsentRecords() }
        notifyChange()
    }

    /// Shared SDK send-result handler; CKSyncEngine event result initializers are not public.
    func recordSentRecords(_ savedRecords: [CKRecord], failedSaves: [(record: CKRecord, error: CKError)],
                           syncEngine: CKSyncEngine) throws {
        guard engine === syncEngine else { return }
        var errors: [CKError] = []
        try recordSavedRecords(savedRecords, syncEngine: syncEngine)
        for failure in failedSaves {
            switch failure.error.code {
            case .serverRecordChanged:
                if let server = failure.error.serverRecord {
                    try receive(server)
                } else {
                    errors.append(failure.error)
                }
            case .limitExceeded:
                try handleLimitExceeded(record: failure.record, syncEngine: syncEngine)
            case .zoneNotFound, .unknownItem:
                try recoverMissingZone(syncEngine: syncEngine)
                errors.append(failure.error)
            default:
                errors.append(failure.error)
            }
        }
        try persist(state)
        recordOperationResult(errors: errors, syncEngine: syncEngine)
        guard engine === syncEngine else { return }
        enqueueUnsentRecords()
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await recordZoneChangeBatch(scope: context.options.scope, syncEngine: syncEngine)
    }

    // SDK send contexts have no public initializer; exercise this same provider in tests.
    func recordZoneChangeBatch(
        scope: CKSyncEngine.SendChangesOptions.Scope, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard engine === syncEngine else { return nil }
        if !zoneAvailable { batchPauseReason = "zone_not_ready"; return nil }
        if !currentFetchSucceeded { batchPauseReason = "fetch_not_complete"; return nil }
        if !appliedCurrentFetch || !localAuthorityReady { batchPauseReason = "projection_not_applied"; return nil }
        guard status == .active || status == .retrying else { batchPauseReason = "transport_unavailable"; return nil }
        do {
            // SDK recordIDs Scope.contains performs a linear search. A frozen large
            // request must not turn every batch into an O(pending × target) traversal.
            let includedIDs: Set<CKRecord.ID>?
            if case let .recordIDs(ids) = scope { includedIDs = Set(ids) } else { includedIDs = nil }
            let pending = syncEngine.state.pendingRecordZoneChanges.compactMap { change -> String? in
                guard case let .saveRecord(id) = change,
                      includedIDs?.contains(id) ?? scope.contains(id) else { return nil }
                return id.recordName
            }
            var records: [CKRecord] = []
            var batchBytes = 0
            for name in pending {
                guard let key = keysByRecordName[name], let value = state.replica.records[key] else {
                    throw ProtectedLedgerReplica.Failure.malformedRecord
                }
                if case .recordIDs = scope, let target = activeSendTarget,
                   let revision = target.revisions[key], let uploaded = state.uploadedRevisions[name],
                   uploaded >= revision { continue }
                if let blocked = state.oversizedRecords?[key], blocked.revision == value.revision { continue }
                let envelope = Envelope(
                    format: ProtectedLedgerReplica.currentFormat,
                    accountIdentifier: state.replica.accountIdentifier,
                    key: key,
                    record: value
                )
                let encoded = try JSONEncoder().encode(envelope)
                if encoded.count > Self.maximumEnvelopeBytes {
                    try quarantineOversized(key: key, revision: value.revision, bytes: encoded.count)
                    continue
                }
                state.oversizedRecords?.removeValue(forKey: key)
                let estimatedBytes = encoded.count + (state.systemFields[name]?.count ?? 0) + 2_048
                if !records.isEmpty && (batchBytes + estimatedBytes > Self.maximumBatchBytes || records.count >= batchRecordLimit) { break }
                let record: CKRecord
                if let data = state.systemFields[name] {
                    let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
                    decoder.requiresSecureCoding = true
                    defer { decoder.finishDecoding() }
                    guard let restored = CKRecord(coder: decoder) else {
                        throw ProtectedLedgerReplica.Failure.malformedRecord
                    }
                    record = restored
                } else {
                    record = CKRecord(
                        recordType: Self.recordType,
                        recordID: .init(recordName: name, zoneID: Self.zoneID)
                    )
                }
                record["envelope"] = encoded as CKRecordValue
                batchBytes += estimatedBytes
                records.append(record)
            }
            let prepared = Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0) })
            let batch = await CKSyncEngine.RecordZoneChangeBatch(
                pendingChanges: records.map { .saveRecord($0.recordID) }
            ) { prepared[$0] }
            // The SDK initializer suspends; OFF/account-change can happen while it builds.
            guard engine === syncEngine, zoneAvailable, currentFetchSucceeded, appliedCurrentFetch, localAuthorityReady else { return nil }
            lastBatchRecordCount = batch?.recordsToSave.count ?? 0
            batchPauseReason = lastBatchRecordCount > 0 ? nil : (pendingUploadCount > 0 ? "blocked_or_outside_scope" : "no_pending_records")
            if lastBatchRecordCount > 0 { trace("batch_provided", count: lastBatchRecordCount) }
            for record in batch?.recordsToSave ?? [] {
                inFlight[record.recordID.recordName] = try decode(record).record.revision
            }
            return batch
        } catch {
            batchPauseReason = "batch_preparation_failed"
            failures[.upload] = [SyncFailure.capture(error, phase: "batchPreparation")]
            pauseForAccountChange(syncEngine, status: .needsAttention)
            return nil
        }
    }

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        fetchOptions(context.options, syncEngine: syncEngine)
    }

    // FetchChangesContext has no public initializer. Keep the delegate's decision testable
    // using real engine identities without manufacturing SDK event/context values.
    func fetchOptions(
        _ original: CKSyncEngine.FetchChangesOptions, syncEngine: CKSyncEngine
    ) -> CKSyncEngine.FetchChangesOptions {
        var options = original
        guard engine === syncEngine else {
            // A non-nil empty set includes no record zones; .all would reopen the scope.
            options.scope = .zoneIDs([])
            options.prioritizedZoneIDs = []
            return options
        }
        options.scope = .zoneIDs([Self.zoneID])
        return options
    }

    func recordFetchStarted(syncEngine: CKSyncEngine) {
        guard engine === syncEngine else { return }
        fetchGeneration &+= 1
        receiving = true
        currentFetchSucceeded = false
        appliedCurrentFetch = false
        fetchFailed = false
        notifyChange()
    }

    func finishFetchRound(syncEngine: CKSyncEngine) throws {
        try recordFetchCompletion(succeeded: !fetchFailed && zoneAvailable, syncEngine: syncEngine)
    }

    func recordFetchCompletion(succeeded: Bool, syncEngine: CKSyncEngine) throws {
        guard engine === syncEngine else { return }
        fetchGeneration &+= 1
        receiving = false
        currentFetchSucceeded = succeeded
        appliedCurrentFetch = false
        if succeeded {
            zoneAvailable = true
            failures.removeValue(forKey: .download)
            failures.removeValue(forKey: .databaseDownload)
            if state.initialFetchCompleted != true {
                var next = state
                next.initialFetchCompleted = true
                try persist(next)
                state = next
            }
            hasCompletedFetch = true
            status = failures.isEmpty ? .active : .retrying
        }
        notifyChange()
    }

    func handleLimitExceeded(record: CKRecord, syncEngine: CKSyncEngine) throws {
        guard engine === syncEngine else { return }
        if lastBatchRecordCount > 1 {
            let reduced = max(1, lastBatchRecordCount / 2)
            if reduced < batchRecordLimit {
                batchRecordLimit = reduced
                recoveryGeneration &+= 1
                trace("batch_limit_reduced", count: reduced)
            }
        } else {
            let envelope = try decode(record)
            try quarantineOversized(key: envelope.key, revision: envelope.record.revision,
                                    bytes: (record["envelope"] as? Data)?.count ?? 0)
        }
        // Failed and excluded records remain pending. A blocked revision is skipped, so
        // unrelated ledger values continue; editing that value permits a fresh attempt.
        enqueueUnsentRecords()
    }

    private func quarantineOversized(key: String, revision: ProtectedLedgerReplica.Revision, bytes: Int) throws {
        var next = state
        if next.oversizedRecords == nil { next.oversizedRecords = [:] }
        let blocked = OversizedRecord(revision: revision, encodedBytes: bytes)
        guard next.oversizedRecords?[key] != blocked else { return }
        next.oversizedRecords?[key] = blocked
        try persist(next)
        state = next
        recoveryGeneration &+= 1
        trace("revision_quarantined", count: next.oversizedRecords?.count ?? 0)
        notifyChange()
    }

    // The same outcome handler is used by send, zone fetch and database events.
    // A stale success can never revive a stopped, replaced or permanently failed engine.
    func recordOperationResult(errors: [CKError], syncEngine: CKSyncEngine, phase: OperationPhase = .upload) {
        guard engine === syncEngine else { return }
        let hadFailures = !failures.isEmpty
        if !errors.isEmpty, phase == .download || phase == .databaseDownload {
            fetchFailed = true
            currentFetchSucceeded = false
            appliedCurrentFetch = false
        }
        if !errors.isEmpty {
            let captured = SyncFailure.grouped(errors, phase: phase.rawValue)
            failures[phase] = captured
            if let delay = captured.compactMap(\.retryAfter).max() {
                let deadline = now().addingTimeInterval(delay)
                serviceRetryUntil = max(serviceRetryUntil ?? deadline, deadline)
            }
            historicalFailures.append(contentsOf: captured)
            if historicalFailures.count > 8 { historicalFailures.removeFirst(historicalFailures.count - 8) }
            trace("transport_failure", count: errors.count)
        }
        else { failures.removeValue(forKey: phase) }
        if hadFailures, failures.isEmpty { recoveryGeneration &+= 1 }
        if phase == .download, !errors.isEmpty, errors.allSatisfy({ $0.code == .zoneNotFound }) {
            do { try recoverMissingZone(syncEngine: syncEngine); status = .retrying; notifyChange() }
            catch {
                failures[phase] = [SyncFailure.capture(error, phase: "persistence")]
                pauseForAccountChange(syncEngine, status: .needsAttention)
            }
        } else if errors.contains(where: { !SyncFailure.isTransient($0) && !((phase == .upload) && ($0.code == .zoneNotFound || $0.code == .unknownItem)) }) {
            pauseForAccountChange(syncEngine, status: .needsAttention)
        } else {
            status = failures.isEmpty ? .active : .retrying
            notifyChange()
        }
    }

    func recordAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType, syncEngine: CKSyncEngine) {
        guard engine === syncEngine else { return }
        switch change {
        case let .signIn(currentUser):
            guard currentUser.recordName == state.replica.accountIdentifier else {
                pauseForAccountChange(syncEngine, status: .accountChanged)
                return
            }
            enqueueUnsentRecords()
        case .signOut:
            pauseForAccountChange(syncEngine, status: .accountUnavailable)
        case .switchAccounts:
            pauseForAccountChange(syncEngine, status: .accountChanged)
        @unknown default:
            pauseForAccountChange(syncEngine, status: .accountChanged)
        }
    }

    // SDK result structures have no public initializer; deterministic tests call these
    // same handlers. No networking or synchronous waiting occurs inside an event.
    func recordZoneFetchResult(error: CKError?, syncEngine: CKSyncEngine) {
        guard engine === syncEngine else { return }
        if let error {
            fetchFailed = true
            recordOperationResult(errors: [error], syncEngine: syncEngine, phase: .download)
        } else {
            zoneAvailable = true
            recordOperationResult(errors: [], syncEngine: syncEngine, phase: .download)
        }
    }

    func recordDatabaseSendResult(savedZoneIDs: [CKRecordZone.ID], errors: [CKError], syncEngine: CKSyncEngine) {
        guard engine === syncEngine else { return }
        if savedZoneIDs.contains(Self.zoneID) {
            zoneAvailable = true
            if automaticallySync, !currentFetchSucceeded, initializationFetch == nil {
                // Task {} inherits CKSyncEngine's delegate Task-local marker even after
                // this callback returns. Detach only the operation, not ordered event handling.
                initializationFetch = Task.detached { await self.fetchAfterInitialization(syncEngine: syncEngine) }
            }
        }
        recordOperationResult(errors: errors, syncEngine: syncEngine, phase: .databaseUpload)
    }

    private func fetchAfterInitialization(syncEngine: CKSyncEngine) async {
        defer { if engine === syncEngine { initializationFetch = nil } }
        guard engine === syncEngine, !Task.isCancelled else { return }
        do { try await operations.fetchChanges(syncEngine) }
        catch {
            guard engine === syncEngine, !Task.isCancelled else { return }
            if let ck = error as? CKError { recordOperationResult(errors: [ck], syncEngine: syncEngine, phase: .download) }
            else {
                failures[.download] = [SyncFailure.capture(error, phase: "initializationFetch")]
                pauseForAccountChange(syncEngine, status: .needsAttention)
            }
        }
    }

    private func recoverMissingZone(syncEngine: CKSyncEngine) throws {
        guard engine === syncEngine else { return }
        zoneAvailable = false
        currentFetchSucceeded = false
        appliedCurrentFetch = false
        localAuthorityReady = false
        // The cloud disappeared, not the user's ledger. Retain all values and tombstones.
        var next = state
        next.systemFields = [:]
        next.uploadedRevisions = [:]
        try persist(next)
        state = next
        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        enqueueUnsentRecords()
    }

    private func receive(_ record: CKRecord) throws {
        let envelope = try decode(record)
        var next = state
        try next.replica.mergeRecord(
            envelope.record, key: envelope.key, accountIdentifier: envelope.accountIdentifier
        )
        try rememberServerRecord(record, in: &next)
        next.oversizedRecords = next.oversizedRecords?.filter { next.replica.records[$0.key]?.revision == $0.value.revision }
        state = next
        rememberKey(envelope.key)
    }

    // Same durable merge path for delegate delivery and controlled interleaving tests.
    func receiveRemoteRecords(_ records: [CKRecord], syncEngine: CKSyncEngine) throws {
        guard engine === syncEngine else { return }
        for record in records where record.recordID.zoneID == Self.zoneID {
            try receive(record)
        }
        try persist(state)
        appliedCurrentFetch = false
        enqueueUnsentRecords()
    }

    private func rememberServerRecord(_ record: CKRecord, in value: inout State) throws {
        let envelope = try decode(record)
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        value.systemFields[record.recordID.recordName] = coder.encodedData
        value.uploadedRevisions[record.recordID.recordName] = envelope.record.revision
    }

    private func decode(_ record: CKRecord) throws -> Envelope {
        guard record.recordType == Self.recordType,
              record.recordID.zoneID == Self.zoneID,
              let data = record["envelope"] as? Data else {
            throw ProtectedLedgerReplica.Failure.malformedRecord
        }
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        guard value.format == ProtectedLedgerReplica.currentFormat else {
            throw ProtectedLedgerReplica.Failure.unsupportedFormat
        }
        guard value.accountIdentifier == state.replica.accountIdentifier else {
            throw ProtectedLedgerReplica.Failure.differentAccount
        }
        guard Self.recordName(for: value.key) == record.recordID.recordName else {
            throw ProtectedLedgerReplica.Failure.malformedRecord
        }
        return value
    }

    private func enqueueUnsentRecords() {
        let changes: [CKSyncEngine.PendingRecordZoneChange] = state.replica.records.compactMap { key, record in
            guard let name = recordNamesByKey[key] else { return nil }
            guard state.uploadedRevisions[name] != record.revision else { return nil }
            return .saveRecord(.init(recordName: name, zoneID: Self.zoneID))
        }
        pendingUploadCount = changes.count
        // Only exact, durable server receipts retire redundant SDK saves. A newer
        // local revision, unknown key, foreign zone or deletion remains untouched.
        if let engine {
            let acknowledged = engine.state.pendingRecordZoneChanges.filter { change in
                guard case let .saveRecord(id) = change, id.zoneID == Self.zoneID,
                      let key = keysByRecordName[id.recordName], let current = state.replica.records[key],
                      state.uploadedRevisions[id.recordName] == current.revision else { return false }
                return true
            }
            engine.state.remove(pendingRecordZoneChanges: acknowledged)
            engine.state.add(pendingRecordZoneChanges: changes)
        }
    }

    private func rememberKey(_ key: String) {
        let name = Self.recordName(for: key)
        recordNamesByKey[key] = name
        keysByRecordName[name] = key
    }

    private func pauseForAccountChange(_ current: CKSyncEngine, status: Status) {
        guard engine === current else { return }
        engine = nil
        inFlight.removeAll()
        localAuthorityReady = false
        self.status = status
        initializationFetch?.cancel()
        initializationFetch = nil
        scheduleCancellation(current)
        notifyChange()
    }

    private func scheduleCancellation(_ current: CKSyncEngine) {
        let operations = operations
        stoppingID = UUID()
        // Never inherit delegate Task-locals, including via synchronous notifications.
        // Retain the task until stop drains it; start cannot race a retiring engine.
        stoppingTask = Task.detached { await operations.cancelOperations(current) }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func persist(_ value: State) throws {
        let started = Date()
        defer { lastPersistenceDuration = Date().timeIntervalSince(started) }
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(value).write(
            to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    static func recordName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
