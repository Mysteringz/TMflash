import TMflashCore
import XCTest
@testable import TMflash

final class BatchSelectionTests: XCTestCase {
    @MainActor
    private func model(deviceCount: Int) throws -> AppModel {
        let suite = "TMflash.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(live: false, defaults: defaults)
        model.mode = .batch
        model.flashFirmware = false
        model.devices = (0..<deviceCount).map { SerialDevice(path: "/dev/cu.test-\($0)", vendorID: 0x10C4) }
        model.startIDText = "101"
        model.endIDText = String(100 + deviceCount)
        return model
    }

    @MainActor
    func testSelectAllIncludesEveryDetectedBoardBeyondTen() async throws {
        let model = try model(deviceCount: 32)
        model.selectAllBatch()
        XCTAssertEqual(model.batchPorts.count, 32)
        let jobs = try model.plan.get()
        XCTAssertEqual(jobs.map(\.port), model.devices.map(\.path))
        XCTAssertEqual(jobs.map(\.nodeID), Array(101...132))
        XCTAssertTrue(model.blockers.isEmpty)
    }

    @MainActor
    func testEveryDetectedBoardCanBeSelectedIndividually() async throws {
        let model = try model(deviceCount: 16)
        for device in model.devices { model.toggleBatch(device.path) }
        XCTAssertEqual(try model.plan.get().count, 16)
        model.toggleBatch("/dev/cu.not-connected")
        XCTAssertEqual(model.batchPorts.count, 16, "an absent board is not available to flash")
        model.toggleBatch(model.devices[0].path)
        XCTAssertEqual(model.batchPorts.count, 15)
        XCTAssertFalse(model.blockers.isEmpty, "the ID range must still match the selected boards")
    }

    @MainActor
    func testAvailableBatchSizeFollowsConnectedBoards() async throws {
        let model = try model(deviceCount: 16)
        model.selectAllBatch()
        model.devices.removeLast()
        model.endIDText = "115"
        XCTAssertEqual(try model.plan.get().count, 15, "a disconnected board is excluded from the plan")
        model.selectAllBatch()
        XCTAssertEqual(model.batchPorts.count, 15)
        model.devices.append(SerialDevice(path: "/dev/cu.new-board", vendorID: 0x10C4))
        model.endIDText = "116"
        model.selectAllBatch()
        XCTAssertEqual(try model.plan.get().last?.port, "/dev/cu.new-board")
        model.devices = []
        model.selectAllBatch()
        XCTAssertTrue(model.batchPorts.isEmpty)
        XCTAssertFalse(model.blockers.isEmpty)
    }

    @MainActor
    func testExistingBatchPreferenceSurvivesTheLabelChange() async {
        XCTAssertEqual(AppModel.Mode(persistedValue: "Batch (up to 10)"), .batch)
        XCTAssertEqual(AppModel.Mode(persistedValue: "Batch"), .batch)
        XCTAssertEqual(AppModel.Mode(persistedValue: "Single node"), .single)
        XCTAssertEqual(AppModel.Mode(persistedValue: nil), .single)
    }
}
