import Foundation
import CloudKit

/// A ``ContinuityStore`` backed by the user's **private** CloudKit database. Everything
/// stays in the user's own iCloud account — no shared server, matching the app's
/// privacy stance. One record per game (`recordName == romHash`, last-writer-wins).
///
/// The savestate and thumbnail are stored as `CKAsset`s (not inline fields) because a
/// GBA savestate can exceed CloudKit's ~1 MB inline record ceiling. `fetchCard` uses
/// `desiredKeys` to pull metadata + thumbnail while leaving the state asset on the server
/// until the user actually taps Continue.
///
/// Requires the CloudKit entitlement and the matching container to exist. Set
/// `containerIdentifier` to the app's real container (or pass nil to use the default).
public struct CloudKitContinuityStore: ContinuityStore {
    private let containerIdentifier: String?

    public init(containerIdentifier: String? = nil) {
        self.containerIdentifier = containerIdentifier
    }

    private var database: CKDatabase {
        let container = containerIdentifier.map(CKContainer.init(identifier:)) ?? .default()
        return container.privateCloudDatabase
    }

    // MARK: Record schema

    private enum RecordType {
        static let snapshot = "ContinuitySnapshot"
        static let rom = "ContinuityROM"   // separate, ephemeral ROM offer
    }
    private enum Field {
        static let romHash = "romHash"
        static let romTitle = "romTitle"
        static let timestamp = "timestamp"
        static let deviceName = "deviceName"
        static let secondsPlayed = "secondsPlayed"
        static let coreVersion = "coreVersion"
        static let thumbnail = "thumbnail"   // CKAsset
        static let state = "state"           // CKAsset — the heavy one
        static let fileName = "fileName"     // ROM record: original filename
        static let rom = "rom"               // ROM record: CKAsset — the heavy ROM
        static let cover = "cover"           // ROM record: CKAsset — box art (small, optional)
        static let targetDevice = "targetDevice"   // ROM record: addressee deviceName, or absent = broadcast
    }

    /// Keys sufficient to build a ``ContinuityCard`` — deliberately omits `state`.
    private static let cardKeys: [CKRecord.FieldKey] = [
        Field.romHash, Field.romTitle, Field.timestamp,
        Field.deviceName, Field.secondsPlayed, Field.coreVersion, Field.thumbnail,
    ]

    // MARK: ContinuityStore

    public func publish(_ snapshot: ContinuitySnapshot) async throws {
        let recordID = CKRecord.ID(recordName: snapshot.metadata.romHash)

        // Upsert: fetch-then-mutate so we overwrite the existing session in place.
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: RecordType.snapshot, recordID: recordID)
        } catch {
            throw mapAccountError(error)
        }

        let m = snapshot.metadata
        record[Field.romHash] = m.romHash as CKRecordValue
        record[Field.romTitle] = m.romTitle as CKRecordValue
        record[Field.timestamp] = m.timestamp as CKRecordValue
        record[Field.deviceName] = m.deviceName as CKRecordValue
        record[Field.secondsPlayed] = Int64(m.secondsPlayed) as CKRecordValue
        record[Field.coreVersion] = m.coreVersion as CKRecordValue

        // Assets must live in files during the upload; clean them up afterward.
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let stateURL = scratch.appendingPathComponent("state.bin")
        try snapshot.state.write(to: stateURL)
        record[Field.state] = CKAsset(fileURL: stateURL)

        if let thumb = snapshot.thumbnailPNG {
            let thumbURL = scratch.appendingPathComponent("thumb.png")
            try thumb.write(to: thumbURL)
            record[Field.thumbnail] = CKAsset(fileURL: thumbURL)
        } else {
            record[Field.thumbnail] = nil
        }

        do {
            _ = try await database.save(record)
        } catch {
            throw mapAccountError(error)
        }
    }

    public func fetchCard(romHash: String) async throws -> ContinuityCard? {
        let recordID = CKRecord.ID(recordName: romHash)
        let results: [CKRecord.ID: Result<CKRecord, Error>]
        do {
            results = try await database.records(for: [recordID], desiredKeys: Self.cardKeys)
        } catch {
            throw mapAccountError(error)
        }
        guard let result = results[recordID] else { return nil }
        let record: CKRecord
        do {
            record = try result.get()
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        let metadata = try metadata(from: record)
        let thumb = (record[Field.thumbnail] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
        return ContinuityCard(metadata: metadata, thumbnailPNG: thumb)
    }

    public func fetchState(romHash: String) async throws -> Data? {
        let recordID = CKRecord.ID(recordName: romHash)
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw mapAccountError(error)
        }
        guard let asset = record[Field.state] as? CKAsset, let url = asset.fileURL else {
            throw ContinuityError.malformedRecord(reason: "snapshot record has no state asset")
        }
        return try Data(contentsOf: url)
    }

    public func delete(romHash: String) async throws {
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: romHash))
        } catch let error as CKError where error.code == .unknownItem {
            // Already gone — deleting is idempotent.
        } catch {
            throw mapAccountError(error)
        }
    }

    public func allCards() async throws -> [ContinuityCard] {
        let query = CKQuery(
            recordType: RecordType.snapshot,
            predicate: NSPredicate(value: true))
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: Self.cardKeys)
            var cards: [ContinuityCard] = []
            for (_, result) in matches {
                guard let record = try? result.get() else { continue }
                let metadata = try metadata(from: record)
                let thumb = (record[Field.thumbnail] as? CKAsset)?.fileURL
                    .flatMap { try? Data(contentsOf: $0) }
                cards.append(ContinuityCard(metadata: metadata, thumbnailPNG: thumb))
            }
            return cards
        } catch let error as CKError where error.code == .unknownItem {
            return []   // no records / schema not yet materialized
        } catch {
            throw mapAccountError(error)
        }
    }

    // MARK: ROM transfer

    /// The ROM offer lives in its own record; `recordName` must be unique per database (across
    /// record types), so it can't reuse the snapshot's `romHash` — we namespace it.
    private func romRecordID(_ romHash: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "rom:\(romHash)")
    }

    public func publishROM(romHash: String, fileName: String, coverPNG: Data?, data: Data) async throws {
        try await publishROM(romHash: romHash, fileName: fileName, coverPNG: coverPNG, data: data, targetDevice: nil)
    }

    public func publishROM(romHash: String, fileName: String, coverPNG: Data?, data: Data, targetDevice: String?) async throws {
        let recordID = romRecordID(romHash)
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: RecordType.rom, recordID: recordID)
        } catch {
            throw mapAccountError(error)
        }
        record[Field.fileName] = fileName as CKRecordValue
        record[Field.targetDevice] = targetDevice as CKRecordValue?   // nil = broadcast

        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let romURL = scratch.appendingPathComponent("rom.bin")
        try data.write(to: romURL)
        record[Field.rom] = CKAsset(fileURL: romURL)

        if let coverPNG {
            let coverURL = scratch.appendingPathComponent("cover.png")
            try coverPNG.write(to: coverURL)
            record[Field.cover] = CKAsset(fileURL: coverURL)
        } else {
            record[Field.cover] = nil
        }

        do {
            _ = try await database.save(record)
        } catch {
            throw mapAccountError(error)
        }
    }

    public func fetchROMCover(romHash: String) async throws -> Data? {
        let record: CKRecord
        do {
            record = try await database.record(for: romRecordID(romHash))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw mapAccountError(error)
        }
        guard let asset = record[Field.cover] as? CKAsset, let url = asset.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    public func fetchROMInfo(romHash: String) async throws -> String? {
        let recordID = romRecordID(romHash)
        do {
            let results = try await database.records(
                for: [recordID], desiredKeys: [Field.fileName])
            guard let result = results[recordID] else { return nil }
            let record = try result.get()
            return record[Field.fileName] as? String
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw mapAccountError(error)
        }
    }

    public func fetchROMTarget(romHash: String) async throws -> String? {
        let recordID = romRecordID(romHash)
        do {
            let results = try await database.records(
                for: [recordID], desiredKeys: [Field.targetDevice])
            guard let result = results[recordID] else { return nil }
            return try result.get()[Field.targetDevice] as? String
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw mapAccountError(error)
        }
    }

    public func fetchROM(romHash: String) async throws -> Data? {
        let record: CKRecord
        do {
            record = try await database.record(for: romRecordID(romHash))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw mapAccountError(error)
        }
        guard let asset = record[Field.rom] as? CKAsset, let url = asset.fileURL else { return nil }
        return try Data(contentsOf: url)
    }

    public func clearROM(romHash: String) async throws {
        do {
            _ = try await database.deleteRecord(withID: romRecordID(romHash))
        } catch let error as CKError where error.code == .unknownItem {
            // Already gone — deleting is idempotent.
        } catch {
            throw mapAccountError(error)
        }
    }

    // MARK: Helpers

    private func metadata(from record: CKRecord) throws -> ContinuityMetadata {
        guard
            let romHash = record[Field.romHash] as? String,
            let romTitle = record[Field.romTitle] as? String,
            let timestamp = record[Field.timestamp] as? Date,
            let deviceName = record[Field.deviceName] as? String,
            let seconds = record[Field.secondsPlayed] as? Int64,
            let coreVersion = record[Field.coreVersion] as? String
        else {
            throw ContinuityError.malformedRecord(reason: "snapshot record missing metadata fields")
        }
        return ContinuityMetadata(
            romHash: romHash,
            romTitle: romTitle,
            timestamp: timestamp,
            deviceName: deviceName,
            secondsPlayed: Int(seconds),
            coreVersion: coreVersion
        )
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Translate the CloudKit errors that mean "iCloud isn't usable right now" into our
    /// own type so callers can distinguish them from genuine failures.
    private func mapAccountError(_ error: Error) -> Error {
        guard let ck = error as? CKError else { return error }
        switch ck.code {
        case .notAuthenticated, .accountTemporarilyUnavailable,
             .networkUnavailable, .networkFailure, .serviceUnavailable:
            return ContinuityError.cloudUnavailable(underlying: ck.localizedDescription)
        default:
            return error
        }
    }
}
