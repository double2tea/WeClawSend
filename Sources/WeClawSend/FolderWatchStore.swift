import Combine
import Foundation

@MainActor
final class FolderWatchStore: ObservableObject {
    static let rulesDefaultsKey = "FolderWatchRules"
    static let recordsDefaultsKey = "FolderWatchRecords"
    static let maximumRecentRecords = 20
    static let maximumActiveRecords = 20

    @Published private(set) var rules: [FolderWatchRule]
    @Published private(set) var records: [FolderWatchRecord]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var seenRuleIDs = Set<UUID>()
        let decodedRules = Self.decode(
            [FolderWatchRule].self,
            from: defaults.data(forKey: Self.rulesDefaultsKey)
        ).map { $0.normalized() }
        self.rules = decodedRules.filter { seenRuleIDs.insert($0.id).inserted }
        let decodedRecords = Self.decode(
            [FolderWatchRecord].self,
            from: defaults.data(forKey: Self.recordsDefaultsKey)
        )
        let didRecoverProcessingRecord = decodedRecords.contains { $0.status == .processing }
        self.records = Self.trimmedRecords(
            decodedRecords.map { record in
                    guard record.status == .processing else { return record }
                    var recovered = record
                    recovered.status = .failed
                    recovered.message = "应用上次退出时未确认处理完成"
                    return recovered
                }
        )
        if rules.count != decodedRules.count || didRecoverProcessingRecord
            || defaults.data(forKey: Self.rulesDefaultsKey) != nil {
            persist()
        }
    }

    func rule(id: UUID) -> FolderWatchRule? {
        rules.first { $0.id == id }
    }

    func pathCheck(
        folderPath: String,
        includesSubfolders: Bool,
        excluding ruleID: UUID? = nil
    ) -> FolderWatchPathCheck {
        let normalizedPath = Self.comparisonPath(FolderWatchRule.normalizePath(folderPath))
        guard !normalizedPath.isEmpty else { return .invalidPath }

        for existing in rules where existing.id != ruleID {
            let existingPath = Self.comparisonPath(existing.folderPath)
            if existingPath == normalizedPath {
                return .duplicate(existingRuleID: existing.id)
            }
            if Self.rulesOverlap(
                existingPath: existingPath,
                existingIncludesSubfolders: existing.includesSubfolders,
                candidatePath: normalizedPath,
                candidateIncludesSubfolders: includesSubfolders
            ) {
                return .overlaps(existingRuleID: existing.id)
            }
        }
        return .available
    }

    @discardableResult
    func addRule(_ rule: FolderWatchRule) throws -> FolderWatchRule {
        let normalized = rule.normalized()
        guard self.rule(id: normalized.id) == nil else {
            throw FolderWatchStoreError.duplicateID(normalized.id)
        }
        try validate(normalized)
        rules.append(normalized)
        persist()
        return normalized
    }

    @discardableResult
    func updateRule(_ rule: FolderWatchRule) throws -> FolderWatchRule {
        let normalized = rule.normalized()
        guard let index = rules.firstIndex(where: { $0.id == normalized.id }) else {
            throw FolderWatchStoreError.ruleNotFound(normalized.id)
        }
        try validate(normalized)
        rules[index] = normalized
        persist()
        return normalized
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
        records.removeAll { $0.ruleID == id }
        persist()
    }

    func setRuleEnabled(_ enabled: Bool, id: UUID) throws {
        guard var rule = rule(id: id) else {
            throw FolderWatchStoreError.ruleNotFound(id)
        }
        rule.enabled = enabled
        try updateRule(rule)
    }

    func appendRecord(_ record: FolderWatchRecord) {
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        trimRecords()
        persist()
    }

    func updateRecord(
        id: UUID,
        status: FolderWatchRecordStatus,
        message: String? = nil
    ) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = status
        records[index].message = message
        persist()
    }

    func clearRecords() {
        records.removeAll()
        persist()
    }

    private func validate(_ rule: FolderWatchRule) throws {
        guard !rule.folderPath.isEmpty else { throw FolderWatchStoreError.invalidPath }
        var routeIDs = Set<UUID>()
        for route in rule.routes {
            guard routeIDs.insert(route.id).inserted else {
                throw FolderWatchStoreError.duplicateRouteID(route.id)
            }
        }
        for firstIndex in rule.routes.indices {
            for secondIndex in rule.routes.indices where secondIndex > firstIndex {
                if Self.routesOverlap(rule.routes[firstIndex], rule.routes[secondIndex]) {
                    throw FolderWatchStoreError.overlappingRoutes
                }
            }
        }
        switch pathCheck(
            folderPath: rule.folderPath,
            includesSubfolders: rule.includesSubfolders,
            excluding: rule.id
        ) {
        case .available:
            return
        case .invalidPath:
            throw FolderWatchStoreError.invalidPath
        case let .duplicate(existingRuleID):
            throw FolderWatchStoreError.duplicate(existingRuleID: existingRuleID)
        case let .overlaps(existingRuleID):
            throw FolderWatchStoreError.overlaps(existingRuleID: existingRuleID)
        }
    }

    private func trimRecords() {
        records = Self.trimmedRecords(records)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let rulesData = try? encoder.encode(rules) {
            defaults.set(rulesData, forKey: Self.rulesDefaultsKey)
        }
        if let recordsData = try? encoder.encode(records) {
            defaults.set(recordsData, forKey: Self.recordsDefaultsKey)
        }
    }

    private static func decode<Element: Decodable>(
        _ type: [Element].Type,
        from data: Data?
    ) -> [Element] {
        guard let data, !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(type, from: data)) ?? []
    }

    private static func trimmedRecords(_ records: [FolderWatchRecord]) -> [FolderWatchRecord] {
        let sorted = records.sorted { $0.discoveredAt > $1.discoveredAt }
        let active = sorted.filter { record in
            record.status == .waiting || record.status == .processing || record.status == .discovered
        }
        let terminal = sorted.filter { record in
            record.status != .waiting && record.status != .processing && record.status != .discovered
        }
        return (active.prefix(maximumActiveRecords) + terminal.prefix(maximumRecentRecords))
            .sorted { $0.discoveredAt > $1.discoveredAt }
    }

    private static func comparisonPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let supportsCaseSensitiveNames = try? url.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames
        return supportsCaseSensitiveNames == false ? path.lowercased() : path
    }

    private static func routesOverlap(_ lhs: FolderWatchRoute, _ rhs: FolderWatchRoute) -> Bool {
        guard let lhsExtensions = routedExtensions(lhs),
              let rhsExtensions = routedExtensions(rhs) else {
            return true
        }
        return !lhsExtensions.isDisjoint(with: rhsExtensions)
    }

    private static func routedExtensions(_ route: FolderWatchRoute) -> Set<String>? {
        if route.fileTypeAllowlist.contains(.all) { return nil }
        var extensions = route.fileTypeAllowlist
            .filter { $0 != .all && $0 != .custom }
            .reduce(into: Set<String>()) { result, type in
                result.formUnion(type.extensions)
            }
        if route.fileTypeAllowlist.contains(.custom) {
            extensions.formUnion(route.customExtensions)
        }
        return extensions
    }

    private static func rulesOverlap(
        existingPath: String,
        existingIncludesSubfolders: Bool,
        candidatePath: String,
        candidateIncludesSubfolders: Bool
    ) -> Bool {
        if existingIncludesSubfolders && isDescendant(candidatePath, of: existingPath) {
            return true
        }
        if candidateIncludesSubfolders && isDescendant(existingPath, of: candidatePath) {
            return true
        }
        return false
    }

    private static func isDescendant(_ child: String, of parent: String) -> Bool {
        guard child != parent else { return false }
        if parent == "/" { return child.hasPrefix("/") }
        return child.hasPrefix(parent + "/")
    }
}
