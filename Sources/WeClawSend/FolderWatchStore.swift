import Combine
import Foundation

@MainActor
final class FolderWatchStore: ObservableObject {
    static let rulesDefaultsKey = "FolderWatchRules"
    static let recordsDefaultsKey = "FolderWatchRecords"
    static let maximumRecentRecords = 20

    @Published private(set) var rules: [FolderWatchRule]
    @Published private(set) var records: [FolderWatchRecord]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rules = Self.decode([FolderWatchRule].self, from: defaults.data(forKey: Self.rulesDefaultsKey))
            .map { $0.normalized() }
        self.records = Array(
            Self.decode([FolderWatchRecord].self, from: defaults.data(forKey: Self.recordsDefaultsKey))
                .sorted { $0.discoveredAt > $1.discoveredAt }
                .prefix(Self.maximumRecentRecords)
        )
    }

    func rule(id: UUID) -> FolderWatchRule? {
        rules.first { $0.id == id }
    }

    func pathCheck(
        folderPath: String,
        includesSubfolders: Bool,
        excluding ruleID: UUID? = nil
    ) -> FolderWatchPathCheck {
        let normalizedPath = FolderWatchRule.normalizePath(folderPath)
        guard !normalizedPath.isEmpty else { return .invalidPath }

        for existing in rules where existing.id != ruleID {
            if existing.folderPath == normalizedPath {
                return .duplicate(existingRuleID: existing.id)
            }
            if Self.rulesOverlap(
                existingPath: existing.folderPath,
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
        if records.count > Self.maximumRecentRecords {
            records = Array(records.prefix(Self.maximumRecentRecords))
        }
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
