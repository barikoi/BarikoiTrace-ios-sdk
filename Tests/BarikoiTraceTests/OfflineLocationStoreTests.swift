import XCTest
@testable import BarikoiTrace

final class OfflineLocationStoreTests: XCTestCase {

    private func makeStore() -> OfflineLocationStore {
        // In-memory DB per test — mirrors OfflineLocationDaoTest's isolation
        // approach on the Kotlin side, without touching disk.
        OfflineLocationStore(path: ":memory:")
    }

    func testInsertAndCount() {
        let store = makeStore()
        XCTAssertEqual(store.count(), 0)

        store.insert(json: "{\"latitude\":1.0}")
        store.insert(json: "{\"latitude\":2.0}")

        XCTAssertEqual(store.count(), 2)
    }

    func testBatchReturnsOldestFirst() {
        let store = makeStore()
        store.insert(json: "{\"seq\":1}")
        store.insert(json: "{\"seq\":2}")
        store.insert(json: "{\"seq\":3}")

        let batch = store.batch(limit: 100)
        XCTAssertEqual(batch.count, 3)
        XCTAssertEqual(batch.first?.json, "{\"seq\":1}")
        XCTAssertEqual(batch.last?.json, "{\"seq\":3}")
    }

    func testBatchRespectsLimit() {
        let store = makeStore()
        for i in 0..<150 {
            store.insert(json: "{\"seq\":\(i)}")
        }

        XCTAssertEqual(store.count(), 150)
        XCTAssertEqual(store.batch(limit: 100).count, 100)
    }

    func testDeleteBatchRemovesOldestOnly() {
        let store = makeStore()
        for i in 0..<150 {
            store.insert(json: "{\"seq\":\(i)}")
        }

        store.deleteBatch(limit: 100)
        XCTAssertEqual(store.count(), 50)

        let remaining = store.batch(limit: 100)
        XCTAssertEqual(remaining.first?.json, "{\"seq\":100}")
    }

    func testSurvivesEmptyDeleteBatch() {
        let store = makeStore()
        store.deleteBatch(limit: 100) // no rows — should not crash
        XCTAssertEqual(store.count(), 0)
    }
}
