import XCTest
@testable import ContinuityKit

final class ContinuityKitTests: XCTestCase {

    private func snapshot(
        romHash: String = "abc123",
        coreVersion: String = "mgba-0.10.3",
        state: Data = Data([0x01, 0x02, 0x03]),
        thumb: Data? = Data([0xFF])
    ) -> ContinuitySnapshot {
        let meta = ContinuityMetadata(
            romHash: romHash,
            romTitle: "Test Game",
            deviceName: "Austin's iPhone",
            secondsPlayed: 42,
            coreVersion: coreVersion
        )
        return ContinuitySnapshot(metadata: meta, state: state, thumbnailPNG: thumb)
    }

    // MARK: version gate

    func testVersionGateMatchesExactly() {
        let meta = snapshot(coreVersion: "mgba-0.10.3").metadata
        XCTAssertTrue(meta.isRestorable(byCoreVersion: "mgba-0.10.3"))
        XCTAssertFalse(meta.isRestorable(byCoreVersion: "mgba-0.10.4"))
    }

    // MARK: in-memory store contract

    func testFetchCardReturnsMetadataAndThumbButNotState() async throws {
        let store = InMemoryContinuityStore()
        try await store.publish(snapshot())

        let card = try await store.fetchCard(romHash: "abc123")
        XCTAssertEqual(card?.metadata.romTitle, "Test Game")
        XCTAssertEqual(card?.thumbnailPNG, Data([0xFF]))
    }

    func testFetchStateReturnsPayload() async throws {
        let store = InMemoryContinuityStore()
        try await store.publish(snapshot(state: Data([9, 8, 7])))
        let state = try await store.fetchState(romHash: "abc123")
        XCTAssertEqual(state, Data([9, 8, 7]))
    }

    func testPublishIsLastWriterWinsPerRomHash() async throws {
        let store = InMemoryContinuityStore()
        try await store.publish(snapshot(state: Data([1])))
        try await store.publish(snapshot(state: Data([2])))
        let count = await store.count
        XCTAssertEqual(count, 1)
        let state = try await store.fetchState(romHash: "abc123")
        XCTAssertEqual(state, Data([2]))
    }

    func testMissingGameReturnsNilNotError() async throws {
        let store = InMemoryContinuityStore()
        let card = try await store.fetchCard(romHash: "nope")
        XCTAssertNil(card)
        let state = try await store.fetchState(romHash: "nope")
        XCTAssertNil(state)
    }

    func testDeleteIsIdempotent() async throws {
        let store = InMemoryContinuityStore()
        try await store.publish(snapshot())
        try await store.delete(romHash: "abc123")
        try await store.delete(romHash: "abc123") // second delete must not throw
        let card = try await store.fetchCard(romHash: "abc123")
        XCTAssertNil(card)
    }

    // MARK: coordinator

    func testResumeReturnsStateWhenVersionMatches() async throws {
        let store = InMemoryContinuityStore()
        try await store.publish(snapshot(coreVersion: "mgba-0.10.3", state: Data([5, 5])))
        let coord = ContinuityCoordinator(store: store, coreVersion: "mgba-0.10.3", deviceName: "Mac")
        let state = try await coord.resumeState(forRomHash: "abc123")
        XCTAssertEqual(state, Data([5, 5]))
    }

    func testResumeThrowsOnVersionMismatch() async throws {
        let store = InMemoryContinuityStore()
        try await store.publish(snapshot(coreVersion: "mgba-0.10.3"))
        let coord = ContinuityCoordinator(store: store, coreVersion: "mgba-0.10.9", deviceName: "Mac")
        do {
            _ = try await coord.resumeState(forRomHash: "abc123")
            XCTFail("expected incompatibleCoreVersion")
        } catch let ContinuityError.incompatibleCoreVersion(snapshotVersion, current) {
            XCTAssertEqual(snapshotVersion, "mgba-0.10.3")
            XCTAssertEqual(current, "mgba-0.10.9")
        }
    }

    func testResumeReturnsNilWhenNoSnapshot() async throws {
        let store = InMemoryContinuityStore()
        let coord = ContinuityCoordinator(store: store, coreVersion: "v1", deviceName: "Mac")
        let state = try await coord.resumeState(forRomHash: "missing")
        XCTAssertNil(state)
    }

    func testMakeMetadataStampsDeviceAndCoreVersion() async {
        let coord = ContinuityCoordinator(
            store: InMemoryContinuityStore(), coreVersion: "v2", deviceName: "Austin's Mac")
        let meta = await coord.makeMetadata(romHash: "h", romTitle: "T", secondsPlayed: 10)
        XCTAssertEqual(meta.deviceName, "Austin's Mac")
        XCTAssertEqual(meta.coreVersion, "v2")
    }

    func testImmediatePublishReachesStore() async throws {
        let store = InMemoryContinuityStore()
        let coord = ContinuityCoordinator(store: store, coreVersion: "v1", deviceName: "Mac")
        try await coord.publish(snapshot())
        let card = try await store.fetchCard(romHash: "abc123")
        XCTAssertNotNil(card)
    }

    func testScheduledPublishSupersedesEarlierOne() async throws {
        let store = InMemoryContinuityStore()
        let coord = ContinuityCoordinator(store: store, coreVersion: "v1", deviceName: "Mac")
        // First scheduled publish should be cancelled by the second before it fires.
        await coord.schedulePublish(snapshot(state: Data([1])), debounce: .milliseconds(200))
        await coord.schedulePublish(snapshot(state: Data([2])), debounce: .milliseconds(200))
        try await Task.sleep(for: .milliseconds(500))
        let state = try await store.fetchState(romHash: "abc123")
        XCTAssertEqual(state, Data([2]))
        let count = await store.count
        XCTAssertEqual(count, 1)
    }

    // MARK: codable round-trip

    func testSnapshotCodableRoundTrip() throws {
        let original = snapshot()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContinuitySnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
