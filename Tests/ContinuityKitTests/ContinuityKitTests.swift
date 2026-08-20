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

    // MARK: allCards

    func testAllCardsReturnsEveryStoredSession() async throws {
        let store = InMemoryContinuityStore()
        try await store.publish(snapshot(romHash: "a"))
        try await store.publish(snapshot(romHash: "b"))
        let cards = try await store.allCards()
        XCTAssertEqual(Set(cards.map { $0.metadata.romHash }), ["a", "b"])
    }

    func testCoordinatorAllCardsSortedNewestFirst() async throws {
        let store = InMemoryContinuityStore()
        let old = ContinuityMetadata(
            romHash: "old", romTitle: "Old", timestamp: Date(timeIntervalSince1970: 100),
            deviceName: "Mac", secondsPlayed: 0, coreVersion: "v1")
        let new = ContinuityMetadata(
            romHash: "new", romTitle: "New", timestamp: Date(timeIntervalSince1970: 200),
            deviceName: "Mac", secondsPlayed: 0, coreVersion: "v1")
        try await store.publish(ContinuitySnapshot(metadata: old, state: Data([0])))
        try await store.publish(ContinuitySnapshot(metadata: new, state: Data([0])))
        let coord = ContinuityCoordinator(store: store, coreVersion: "v1", deviceName: "Mac")
        let cards = try await coord.allCards()
        XCTAssertEqual(cards.map { $0.metadata.romHash }, ["new", "old"])
    }

    // MARK: ROM transfer (ephemeral offer)

    func testROMOfferPublishFetchInfoAndBytes() async throws {
        let store = InMemoryContinuityStore()
        try await store.publishROM(romHash: "z", fileName: "Zelda.gba", coverPNG: Data([9, 9]), data: Data([1, 2, 3]))
        let info = try await store.fetchROMInfo(romHash: "z")
        XCTAssertEqual(info, "Zelda.gba")
        let bytes = try await store.fetchROM(romHash: "z")
        XCTAssertEqual(bytes, Data([1, 2, 3]))
        // The sender's box art rides along with the offer.
        let cover = try await store.fetchROMCover(romHash: "z")
        XCTAssertEqual(cover, Data([9, 9]))
    }

    func testROMOfferCarriesBatterySave() async throws {
        // The player's cartridge save rides along with the ROM so the receiver continues their progress.
        let store = InMemoryContinuityStore()
        try await store.publishROM(romHash: "z", fileName: "Zelda.gba", coverPNG: nil, data: Data([1, 2, 3]))
        try await store.publishROMBattery(romHash: "z", data: Data([4, 5, 6]))
        let battery = try await store.fetchROMBattery(romHash: "z")
        XCTAssertEqual(battery, Data([4, 5, 6]))
        // Torn down with the offer, so the cloud copy of the save stays ephemeral too.
        try await store.clearROM(romHash: "z")
        let gone = try await store.fetchROMBattery(romHash: "z")
        XCTAssertNil(gone)
    }

    func testROMBatteryNeedsAnOfferToAttachTo() async throws {
        // No ROM offer → nowhere to attach the save; publishing it is a no-op, not a battery-only offer.
        let store = InMemoryContinuityStore()
        try await store.publishROMBattery(romHash: "orphan", data: Data([1]))
        let battery = try await store.fetchROMBattery(romHash: "orphan")
        XCTAssertNil(battery)
    }

    func testROMOfferCoverIsOptional() async throws {
        let store = InMemoryContinuityStore()
        try await store.publishROM(romHash: "z", fileName: "Zelda.gba", coverPNG: nil, data: Data([1]))
        let cover = try await store.fetchROMCover(romHash: "z")
        XCTAssertNil(cover)
    }

    func testFetchROMInfoNilWhenNoOffer() async throws {
        let store = InMemoryContinuityStore()
        let info = try await store.fetchROMInfo(romHash: "none")
        XCTAssertNil(info)
        let bytes = try await store.fetchROM(romHash: "none")
        XCTAssertNil(bytes)
    }

    func testClearROMMakesOfferEphemeral() async throws {
        let store = InMemoryContinuityStore()
        try await store.publishROM(romHash: "z", fileName: "Zelda.gba", coverPNG: nil, data: Data([1, 2, 3]))
        try await store.clearROM(romHash: "z")   // receiver strips it after import
        let info = try await store.fetchROMInfo(romHash: "z")
        XCTAssertNil(info)
        let bytes = try await store.fetchROM(romHash: "z")
        XCTAssertNil(bytes)
    }

    func testROMOfferIsSeparateFromSnapshot() async throws {
        // Publishing a savestate must not create a ROM offer, and vice-versa.
        let store = InMemoryContinuityStore()
        try await store.publish(snapshot(romHash: "g"))
        var offers = await store.romOfferCount
        XCTAssertEqual(offers, 0)
        try await store.publishROM(romHash: "g", fileName: "G.gba", coverPNG: nil, data: Data([7]))
        offers = await store.romOfferCount
        XCTAssertEqual(offers, 1)
        // The savestate is untouched by clearing the ROM offer.
        try await store.clearROM(romHash: "g")
        let card = try await store.fetchCard(romHash: "g")
        XCTAssertNotNil(card)
    }

    func testCoordinatorROMLifecycle() async throws {
        let store = InMemoryContinuityStore()
        let coord = ContinuityCoordinator(store: store, coreVersion: "v1", deviceName: "Mac")
        try await coord.publishROM(romHash: "z", fileName: "Zelda.gba", coverPNG: nil, data: Data([4, 5]))
        let offer = try await coord.romOffer(forRomHash: "z")
        XCTAssertEqual(offer, "Zelda.gba")
        let bytes = try await coord.fetchROM(forRomHash: "z")
        XCTAssertEqual(bytes, Data([4, 5]))
        try await coord.clearROM(romHash: "z")
        let after = try await coord.romOffer(forRomHash: "z")
        XCTAssertNil(after)
    }

    // MARK: codable round-trip

    func testSnapshotCodableRoundTrip() throws {
        let original = snapshot()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContinuitySnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
