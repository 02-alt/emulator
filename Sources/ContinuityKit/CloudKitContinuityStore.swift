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

    private enum RecordType { static let snapshot = "ContinuitySnapshot" }
    private enum Field {
        static let romHash = "romHash"
        static let romTitle = "romTitle"
        static let timestamp = "timestamp"
        static let deviceName = "deviceName"
        static let secondsPlayed = "secondsPlayed"
        static let coreVersion = "coreVersion"
        static let thumbnail = "thumbnail"   // CKAsset
        static let state = "state"           // CKAsset — the heavy one
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
