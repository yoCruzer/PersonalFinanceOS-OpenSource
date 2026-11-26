import Foundation

/// Pure planning: no model creation, defaults installation, approval persistence or sync capture.
enum CategoryCatalogPlanner {
    enum Readiness: Equatable, Sendable {
        case offline
        case confirmedGraph
        case pendingRemoteGraph
    }

    struct Metadata: Equatable, Sendable {
        let id: UUID
        let seedVersion: Int
        let deletedKeys: Set<String>
    }

    struct Snapshot: Equatable, Sendable {
        let categories: [MetadataEditSnapshot.CategoryValue]
        let metadata: [Metadata]
    }

    enum Installation: String, Sendable {
        case installed
        case availableNotInstalled
        case suppressedByUserIntent
        case pendingRemoteGraph
    }

    enum Change: Equatable, Sendable {
        case none
        case insert
        case updateDisplayAndParent(UUID)
    }

    enum Reason: Equatable, Sendable {
        case customized
        case deleted
        case inactiveParent
        case legacyDeletionNeedsReview
        case samePurposeAlreadyExists
        case nameConflict
        case duplicateStorageKey
        case futureCatalogVersion
        case invalidMetadata
    }

    struct Entry: Identifiable, Equatable, Sendable {
        var id: String { definition.semanticKey }
        let definition: CategoryCatalog.Definition
        let installation: Installation
        let change: Change
        let reason: Reason?
        let selectedByDefault: Bool
    }

    struct Plan: Sendable {
        let snapshot: Snapshot
        let catalogVersion: Int
        let readiness: Readiness
        let entries: [Entry]
        let retainedLegacyIDs: Set<UUID>
        var reusableIDs: [String: UUID] = [:]
        var additionsOnly = false

        var canCommit: Bool {
            readiness != .pendingRemoteGraph && !entries.contains {
                $0.reason == .futureCatalogVersion || $0.reason == .duplicateStorageKey || $0.reason == .invalidMetadata
            }
        }
    }

    /// Incremental installation never alters an existing row or assigns it a new identity.
    static func additions(catalog: CategoryCatalog, snapshot: Snapshot, readiness: Readiness) -> Plan {
        let baseline = make(catalog: catalog, snapshot: snapshot, readiness: readiness)
        guard !baseline.entries.contains(where: { $0.reason == .invalidMetadata || $0.reason == .duplicateStorageKey || $0.reason == .futureCatalogVersion }) else { return baseline }
        let byKey = Dictionary(grouping: snapshot.categories.filter { !$0.defaultDefinitionKey.isEmpty }, by: \.defaultDefinitionKey)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0) })
        let deleted = DefaultFinanceDataService.migratedTombstones(snapshot.metadata.reduce(into: Set<String>()) { $0.formUnion($1.deletedKeys) })
        let deletedLegacyKeys = deleted.intersection(Set(catalog.legacyMappings.filter { $0.action != .reuse }.map(\.oldKey)))
        var reusable: [String: UUID] = [:]
        var roots: [String: Entry] = [:]
        var entries: [Entry] = []
        for definition in catalog.definitions {
            let parentEntry = definition.parentSemanticKey.flatMap { roots[$0] }
            let parentID = definition.parentSemanticKey.flatMap { reusable[$0] }
            let parent = parentID.flatMap { byID[$0] }
            var existing = byKey[definition.storageDefaultKey]?.first
            var reason: Reason?
            if existing == nil {
                // Kind + exact canonical name + a proven parent give a narrow purpose match.
                let matches = snapshot.categories.filter {
                    $0.defaultDefinitionKey.isEmpty && $0.kindRawValue == definition.kind.rawValue && $0.name == definition.name &&
                    $0.parentID == parentID && (definition.parentSemanticKey == nil || parentID != nil)
                }
                if matches.count == 1 { existing = matches.first }
                else if matches.count > 1 || snapshot.categories.contains(where: {
                    $0.kindRawValue == definition.kind.rawValue && $0.name == definition.name &&
                    $0.parentID == parentID && (definition.parentSemanticKey == nil || parentID != nil)
                }) { reason = .nameConflict }
            }
            if existing == nil, definition.semanticKey == CategoryPurposeCompatibility.chargingKey {
                let matches = snapshot.categories.filter { value in
                    let root = value.parentID.flatMap { byID[$0] }
                    return CategoryPurposeCompatibility.matches(semanticKey: definition.semanticKey,
                        kind: CategoryKind(rawValue: value.kindRawValue) ?? .income, name: value.name,
                        storageKey: value.defaultDefinitionKey, parentKind: root.flatMap { CategoryKind(rawValue: $0.kindRawValue) },
                        parentName: root?.name, parentKey: root?.defaultDefinitionKey, parentIsRoot: root != nil && root?.parentID == nil)
                }
                if matches.count == 1 { existing = matches[0]; reason = .samePurposeAlreadyExists }
                else if !matches.isEmpty || snapshot.categories.contains(where: {
                    $0.kindRawValue == definition.kind.rawValue && $0.name == definition.name
                }) { reason = .nameConflict }
            }
            var installation: Installation = existing == nil ? .availableNotInstalled : .installed
            var change: Change = existing == nil ? .insert : .none
            if let existing {
                reusable[definition.semanticKey] = existing.id
                if existing.kindRawValue != definition.kind.rawValue ||
                    (definition.parentSemanticKey == nil && existing.parentID != nil) {
                    reason = .customized
                }
            } else if deleted.contains(definition.storageDefaultKey) ||
                        parentEntry.map({ deleted.contains($0.definition.storageDefaultKey) }) == true {
                reason = .deleted
            } else if parentEntry.map({ $0.reason != nil }) == true ||
                        parent.map({ $0.isHidden || $0.archivedAt != nil }) == true {
                reason = .inactiveParent
            } else if existing == nil, isSuccessorOfDeletedLegacy(definition.semanticKey, deletedKeys: deletedLegacyKeys) {
                reason = .legacyDeletionNeedsReview
            }
            if existing == nil, reason != nil { installation = .suppressedByUserIntent }
            if readiness == .pendingRemoteGraph, existing == nil, reason == nil { installation = .pendingRemoteGraph }
            if existing != nil { change = .none }
            let entry = Entry(definition: definition, installation: installation, change: change, reason: reason,
                selectedByDefault: existing == nil && reason == nil && readiness != .pendingRemoteGraph)
            entries.append(entry)
            if definition.parentSemanticKey == nil { roots[definition.semanticKey] = entry }
        }
        return Plan(snapshot: snapshot, catalogVersion: catalog.proposedCategoryCatalogRevision, readiness: readiness,
            entries: entries, retainedLegacyIDs: baseline.retainedLegacyIDs, reusableIDs: reusable, additionsOnly: true)
    }

    // Suppression only: these prefixes never migrate, rename or reclassify anything.
    // Broad legacy purposes suppress related families; specific purposes name only
    // their synonymous/split leaves (e.g. books includes stationery, not school fees).
    // unrelated families still complete. Empty lists denote special transactions
    // for which this catalog intentionally has no ordinary-income successor.
    static let legacyDeletionSuccessors: [String: [String]] = [
        "expense.dining.takeout-snacks": ["expense.dining.regular-meal", "expense.dining.snacks"],
        "expense.dining.coffee-tea": ["expense.dining.coffee", "expense.dining.tea-drink"],
        "expense.dining.groceries": ["expense.groceries"],
        "expense.shopping": ["expense.household", "expense.clothing", "expense.devices", "expense.childcare", "expense.personal-care"],
        "expense.shopping.daily-goods": ["expense.household.paper-cleaning", "expense.household.toiletries", "expense.household.kitchen", "expense.household.textiles", "expense.household.tools", "expense.household.gardening", "expense.household.other"],
        "expense.shopping.clothing": ["expense.clothing"],
        "expense.shopping.digital": ["expense.devices"],
        "expense.shopping.home": ["expense.household"],
        "expense.shopping.baby-care": ["expense.childcare"],
        "expense.shopping.beauty": ["expense.personal-care.skincare", "expense.personal-care.makeup", "expense.personal-care.beauty"],
        "expense.shopping.other": ["expense.household.other", "expense.clothing.other", "expense.devices.other", "expense.childcare.other", "expense.personal-care.other"],
        "expense.home.rent-mortgage": ["expense.home.rent"],
        "expense.home.utilities": ["expense.home.water", "expense.home.electricity", "expense.home.gas", "expense.home.heating"],
        "expense.home.telecom": ["expense.digital-services.phone-plan", "expense.digital-services.mobile-data", "expense.digital-services.broadband"],
        "expense.home.maintenance": ["expense.home.cleaning", "expense.home.repair"],
        "expense.health-education": ["expense.health", "expense.education"],
        "expense.health-education.medical": ["expense.health.outpatient", "expense.health.medicine", "expense.health.inpatient", "expense.health.dental", "expense.health.vision", "expense.health.vaccine", "expense.health.rehab", "expense.health.devices", "expense.health.other"],
        "expense.health-education.courses": ["expense.education.courses"],
        "expense.health-education.books": ["expense.education.books", "expense.education.stationery"],
        "expense.health-education.other": ["expense.health.other", "expense.education.other"],
        "expense.entertainment.movies-shows": ["expense.entertainment.movie", "expense.entertainment.show"],
        "expense.entertainment.games": ["expense.entertainment.game-purchase", "expense.entertainment.game-topup"],
        "expense.entertainment.sports": ["expense.hobbies.gym", "expense.hobbies.venue", "expense.hobbies.coaching", "expense.hobbies.gear", "expense.hobbies.camping"],
        "expense.entertainment.gatherings": ["expense.entertainment.tabletop", "expense.entertainment.karaoke-bar", "expense.dining.regular-meal"],
        "expense.entertainment.hobbies": ["expense.hobbies"],
        "expense.entertainment.subscriptions": ["expense.digital-services.media", "expense.digital-services.reading", "expense.digital-services.software", "expense.digital-services.ai-tools", "expense.digital-services.cloud-storage", "expense.digital-services.hosting", "expense.hobbies.gym"],
        "expense.travel.transport": ["expense.transportation"],
        "expense.travel.dining": ["expense.dining"],
        "expense.travel.shopping": [
            "expense.household.paper-cleaning", "expense.household.toiletries", "expense.household.kitchen", "expense.household.textiles",
            "expense.household.furniture", "expense.household.appliances", "expense.household.tools", "expense.household.gardening",
            "expense.household.other", "expense.clothing.clothes", "expense.clothing.shoes", "expense.clothing.bags",
            "expense.clothing.underwear", "expense.clothing.jewelry", "expense.clothing.watch", "expense.clothing.other",
            "expense.devices.phone", "expense.devices.computer", "expense.devices.tablet", "expense.devices.peripherals",
            "expense.devices.audio", "expense.devices.wearables", "expense.devices.accessories", "expense.devices.other",
            "expense.personal-care.skincare", "expense.personal-care.makeup", "expense.personal-care.other", "expense.gifts.gifts"
        ],
        "income.work.bonus": ["income.work.performance", "income.work.annual-bonus"],
        "income.work.reimbursement": [],
        "income.investment.interest": ["income.investment.deposit-interest", "income.investment.product-interest"],
        "income.investment.investment-return": ["income.investment.realized"],
        "income.other.refund": [],
    ]

    private static func isSuccessorOfDeletedLegacy(_ semanticKey: String, deletedKeys: Set<String>) -> Bool {
        deletedKeys.contains { key in
            // An unmapped future legacy purpose is not permission to install a split.
            guard let prefixes = legacyDeletionSuccessors[key] else { return true }
            return prefixes.contains { semanticKey == $0 || semanticKey.hasPrefix($0 + ".") }
        }
    }

    static func make(
        catalog: CategoryCatalog,
        snapshot: Snapshot,
        readiness: Readiness
    ) -> Plan {
        let definitions = catalog.definitions
        let bySemantic = Dictionary(uniqueKeysWithValues: definitions.map { ($0.semanticKey, $0) })
        let byKey = Dictionary(grouping: snapshot.categories.filter { !$0.defaultDefinitionKey.isEmpty }, by: \.defaultDefinitionKey)
        let byID = Dictionary(grouping: snapshot.categories, by: \.id)
        let frozen = Dictionary(uniqueKeysWithValues: DefaultFinanceDataService.frozenDefinitions.map { ($0.key, $0) })
        let deletions = DefaultFinanceDataService.migratedTombstones(snapshot.metadata.reduce(into: Set<String>()) { $0.formUnion($1.deletedKeys) })
        let legacyKeys = Set(catalog.legacyMappings.filter { $0.action != .reuse }.map(\.oldKey))
        let futureVersion = snapshot.metadata.contains { $0.seedVersion > catalog.proposedCategoryCatalogRevision }
        let duplicateKeys = byKey.values.contains { $0.count != 1 }
        let invalidMetadata = snapshot.metadata.count != 1 || byID.values.contains { $0.count != 1 }
            || snapshot.categories.contains { value in
                guard CategoryKind(rawValue: value.kindRawValue) != nil else { return true }
                guard let parentID = value.parentID else { return false }
                guard let parent = byID[parentID]?.first else { return true }
                return parent.id == value.id || parent.parentID != nil || parent.kindRawValue != value.kindRawValue
            }
        let entries = definitions.map { definition -> Entry in
            let existing = byKey[definition.storageDefaultKey] ?? []
            let parentDefinition = definition.parentSemanticKey.flatMap { bySemantic[$0] }
            let parent = parentDefinition.flatMap { byKey[$0.storageDefaultKey]?.first }
            var reason: Reason?
            var change: Change = .none
            var installation: Installation = existing.isEmpty ? .availableNotInstalled : .installed

            if invalidMetadata {
                reason = .invalidMetadata
            } else if futureVersion {
                reason = .futureCatalogVersion
            } else if duplicateKeys {
                reason = .duplicateStorageKey
            } else if let value = existing.first {
                let currentParentKey = value.parentID.flatMap { byID[$0]?.first?.defaultDefinitionKey }
                let expectedParentKey = parentDefinition?.storageDefaultKey
                if value.name != definition.name || currentParentKey != expectedParentKey {
                    let oldParent = value.parentID.flatMap { byID[$0]?.first }
                    let parentUnchanged = oldParent.map { parent in
                        frozen[parent.defaultDefinitionKey]?.matches(parent, parentKey: nil) == true
                    } ?? true
                    if parentUnchanged, frozen[definition.storageDefaultKey]?.matches(value, parentKey: currentParentKey) == true {
                        change = .updateDisplayAndParent(value.id)
                    } else {
                        reason = .customized
                    }
                }
            } else {
                change = .insert
                if deletions.contains(definition.storageDefaultKey) || parentDefinition.map({ deletions.contains($0.storageDefaultKey) }) == true {
                    installation = .suppressedByUserIntent
                    reason = .deleted
                } else if let parent, parent.isHidden || parent.archivedAt != nil {
                    installation = .suppressedByUserIntent
                    reason = .inactiveParent
                } else if let parent, let original = frozen[parent.defaultDefinitionKey],
                          !original.matches(parent, parentKey: nil) {
                    installation = .suppressedByUserIntent
                    reason = .customized
                } else if !deletions.intersection(legacyKeys).isEmpty {
                    // The supplied legacy map explicitly forbids guessing successor splits.
                    // Keep additions selectable in preview, but require an explicit choice.
                    installation = .suppressedByUserIntent
                    reason = .legacyDeletionNeedsReview
                }
            }
            if change != .none && snapshot.categories.contains(where: { value in
                value.defaultDefinitionKey != definition.storageDefaultKey &&
                value.kindRawValue == definition.kind.rawValue && value.name == definition.name &&
                (parentDefinition == nil ? value.parentID == nil : parent.map { value.parentID == $0.id } == true)
            }) {
                reason = .nameConflict
            }
            if readiness == .pendingRemoteGraph, existing.isEmpty, reason == nil { installation = .pendingRemoteGraph }
            return Entry(
                definition: definition, installation: installation, change: change, reason: reason,
                selectedByDefault: reason == nil && change != .none && readiness != .pendingRemoteGraph
            )
        }
        return Plan(
            snapshot: snapshot, catalogVersion: catalog.proposedCategoryCatalogRevision,
            readiness: readiness, entries: entries,
            retainedLegacyIDs: Set(snapshot.categories.filter { legacyKeys.contains($0.defaultDefinitionKey) }.map(\.id))
        )
    }
}
